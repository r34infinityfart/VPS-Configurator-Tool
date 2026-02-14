#!/bin/bash
# ==============================================================================
# REBS CLOUD OPS - SYSTEM EDITION (v4.0)
# ==============================================================================

# Strict mode
set -u

# --- Configuration ---
CURRENT_VERSION="4.0"
APP_TITLE="Rebs Cloud Ops v${CURRENT_VERSION}"
BASE_DIR="$HOME/.rebs-cloud"
CONFIG_DIR="$BASE_DIR/configs"
IMG_DIR="$BASE_DIR/images"
VM_DIR="$BASE_DIR/instances"
GLOBAL_LOG="$BASE_DIR/manager.log"
INSTALL_PATH="/usr/local/bin/cloudmanager"
# Replace this URL with your actual raw git file for version checking in the future
UPDATE_URL="https://example.com/version.txt" 

# --- Logging Helper ---
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$GLOBAL_LOG"
}

# --- Initialization & System Install ---
init_system() {
    mkdir -p "$CONFIG_DIR" "$IMG_DIR" "$VM_DIR"
    
    if [ ! -f "$GLOBAL_LOG" ]; then
        echo "Rebs Cloud Ops Log Initialized" > "$GLOBAL_LOG"
    fi

    # Check dependencies
    local deps=("qemu-system-x86_64" "qemu-img" "cloud-localds" "wget" "netstat" "openssl" "nc")
    
    if ! command -v genisoimage &> /dev/null && ! command -v xorriso &> /dev/null; then
        deps+=("genisoimage")
    fi
    if ! command -v whiptail &> /dev/null; then deps+=("whiptail"); fi

    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then missing+=("$dep"); fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "Missing dependencies: ${missing[*]}"
        echo "Installing..."
        sudo apt-get update
        sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils wget net-tools openssl genisoimage whiptail netcat-openbsd
    fi
}

# --- Self-Installer ---
check_install() {
    # If the script is running, but the global command doesn't exist, offer install
    if [ ! -f "$INSTALL_PATH" ]; then
        if (whiptail --title "System Install" --yesno "Do you want to install this script as a system command?\n\nYou will be able to run 'cloudmanager' from anywhere." 10 60); then
            # Copy self to destination
            sudo cp "$0" "$INSTALL_PATH"
            sudo chmod +x "$INSTALL_PATH"
            whiptail --msgbox "Installed! You can now type 'cloudmanager' in your terminal." 8 50
        fi
    fi
}

# --- Version Check ---
check_version() {
    # This is a basic implementation. It requires a raw text file at UPDATE_URL containing just the version number (e.g. "4.1")
    # Using a short timeout so the script doesn't hang if offline
    local remote_version=$(curl -s --max-time 2 "$UPDATE_URL" || echo "$CURRENT_VERSION")
    
    if [[ "$remote_version" != "$CURRENT_VERSION" ]]; then
        whiptail --msgbox "Update Available!\n\nLocal: v$CURRENT_VERSION\nRemote: v$remote_version\n\nPlease update your script." 10 50
    fi
}

# --- UI: Create New VM ---
create_new_vm() {
    log "Starting VM Creation Wizard..."
    
    local os_choice=$(whiptail --title "Select OS" --menu "Choose Image:" 15 60 5 \
        "Ubuntu 24.04" "Noble Numbat" \
        "Ubuntu 22.04" "Jammy Jellyfish" \
        "Debian 12" "Bookworm" \
        "AlmaLinux 9" "Enterprise Linux" 3>&1 1>&2 2>&3)
    
    [ -z "$os_choice" ] && return

    local img_url=""
    local img_name=""
    case $os_choice in
        "Ubuntu 24.04") img_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"; img_name="ubuntu-24.04.img" ;;
        "Ubuntu 22.04") img_url="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"; img_name="ubuntu-22.04.img" ;;
        "Debian 12")    img_url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"; img_name="debian-12.qcow2" ;;
        "AlmaLinux 9")  img_url="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"; img_name="alma-9.qcow2" ;;
    esac

    local vm_name=$(whiptail --inputbox "VM Name (no spaces):" 8 40 "vps-1" 3>&1 1>&2 2>&3)
    [ -z "$vm_name" ] && return
    
    if [ -f "$CONFIG_DIR/$vm_name.conf" ]; then
        whiptail --msgbox "VM '$vm_name' already exists!" 8 40
        return
    fi

    local ram_size=$(whiptail --inputbox "RAM (MB):" 8 40 "2048" 3>&1 1>&2 2>&3)
    local cpu_core=$(whiptail --inputbox "CPU Cores:" 8 40 "2" 3>&1 1>&2 2>&3)
    local disk_size=$(whiptail --inputbox "Disk Size:" 8 40 "10G" 3>&1 1>&2 2>&3)
    local ssh_port=$(whiptail --inputbox "SSH Port (Host):" 8 40 "2222" 3>&1 1>&2 2>&3)
    local user=$(whiptail --inputbox "Username:" 8 40 "admin" 3>&1 1>&2 2>&3)
    local pass=$(whiptail --passwordbox "Password:" 8 40 3>&1 1>&2 2>&3)

    # 1. DOWNLOAD LOGIC
    local target_img="$IMG_DIR/$img_name"
    
    # Zombie killer
    if [ -f "$target_img" ]; then
        local fsize=$(stat -c%s "$target_img")
        if [ "$fsize" -lt 10000000 ]; then
            log "WARNING: Found corrupted/small image. Deleting."
            rm "$target_img"
        fi
    fi

    if [ ! -f "$target_img" ]; then
        log "Downloading $img_url..."
        if ! wget --progress=dot:giga "$img_url" -O "$target_img.tmp" 2>&1 | \
             stdbuf -o0 awk '/%/{print $(NF-1)}' | tr -d '%' | \
             whiptail --gauge "Downloading Image..." 6 50 0; then
             whiptail --msgbox "Download failed!" 8 40
             rm -f "$target_img.tmp"
             return
        fi
        mv "$target_img.tmp" "$target_img"
    fi

    # 2. PROVISIONING
    {
        echo "10"
        local vm_disk="$VM_DIR/$vm_name.qcow2"
        local seed_iso="$VM_DIR/$vm_name-seed.iso"
        
        # Disk Creation
        if ! qemu-img create -f qcow2 -F qcow2 -b "$target_img" "$vm_disk" "$disk_size" >> "$GLOBAL_LOG" 2>&1; then
             qemu-img create -f qcow2 "$vm_disk" "$disk_size" >> "$GLOBAL_LOG" 2>&1
        fi
        echo "40"

        # Password Hash
        local pass_hash=$(openssl passwd -6 "$pass")

        # Cloud-Init
        local user_data="$VM_DIR/user-data.$vm_name.tmp"
        local meta_data="$VM_DIR/meta-data.$vm_name.tmp"

        # NOTE: Removed 'package_update: true' to speed up first boot significantly
        cat > "$user_data" <<EOF
#cloud-config
hostname: $vm_name
manage_etc_hosts: true
users:
  - name: $user
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo, wheel
    shell: /bin/bash
    lock_passwd: false
    passwd: $pass_hash
ssh_pwauth: true
chpasswd:
  list: |
    root:$pass
    $user:$pass
  expire: false
runcmd:
  - systemctl start qemu-guest-agent
EOF

        echo "instance-id: $vm_name" > "$meta_data"
        echo "local-hostname: $vm_name" >> "$meta_data"
        
        echo "70"
        cloud-localds "$seed_iso" "$user_data" "$meta_data" >> "$GLOBAL_LOG" 2>&1
        rm -f "$user_data" "$meta_data"

        echo "100"
    } | whiptail --gauge "Provisioning $vm_name..." 6 50 0
    
    # 3. VERIFICATION
    local vm_disk="$VM_DIR/$vm_name.qcow2"
    local seed_iso="$VM_DIR/$vm_name-seed.iso"

    if [ ! -f "$vm_disk" ] || [ ! -f "$seed_iso" ]; then
        log "CRITICAL ERROR: Provisioning failed."
        whiptail --msgbox "Error: Disk or Seed ISO failed to generate.\nCheck logs." 10 60
        return
    fi

    # Save config
    cat > "$CONFIG_DIR/$vm_name.conf" <<EOF
VM_NAME="$vm_name"
RAM="$ram_size"
CPU="$cpu_core"
DISK="$vm_disk"
SEED="$seed_iso"
PORT="$ssh_port"
USER="$user"
EOF
    # Save the password only locally for user reference in the UI (Optional security risk, but useful for user)
    # Storing plain text passwords is bad practice generally, but useful for this specific helper script.
    echo "#PWD_HINT=$pass" >> "$CONFIG_DIR/$vm_name.conf"

    log "VM $vm_name provisioned."
    whiptail --msgbox "Provisioning Complete." 8 40
}

# --- Logic: Start VM ---
start_vm_logic() {
    local vm=$1
    source "$CONFIG_DIR/$vm.conf"
    local pid_file="$VM_DIR/$vm.pid"
    local console_log="$VM_DIR/$vm.console.log"
    local qemu_err="$VM_DIR/$vm.qemu.err"

    if [ -f "$pid_file" ] && kill -0 $(cat "$pid_file") 2>/dev/null; then
        whiptail --msgbox "VM is already running." 8 40
        return
    fi

    if netstat -tuln | grep -q ":$PORT "; then
        whiptail --msgbox "Error: Port $PORT is already in use." 8 50
        return
    fi

    local accel_args=""
    if [ -w /dev/kvm ]; then
        accel_args="-enable-kvm -cpu host"
    else
        accel_args="-accel tcg -cpu qemu64"
    fi

    > "$qemu_err"
    > "$console_log"

    qemu-system-x86_64 \
        -name "$VM_NAME" \
        $accel_args \
        -m "$RAM" \
        -smp "$CPU" \
        -drive file="$DISK",if=virtio,format=qcow2 \
        -drive file="$SEED",if=virtio,format=raw,media=cdrom \
        -netdev user,id=n1,hostfwd=tcp::$PORT-:22 \
        -device virtio-net-pci,netdev=n1 \
        -object rng-random,filename=/dev/urandom,id=rng0 \
        -device virtio-rng-pci,rng=rng0 \
        -device virtio-balloon-pci \
        -nographic \
        -serial file:"$console_log" \
        -monitor none \
        -pidfile "$pid_file" \
        2> "$qemu_err" & 

    # Wait logic
    {
        for i in {1..20}; do
            echo $((i * 5))
            sleep 0.2
        done
    } | whiptail --gauge "Booting VM..." 6 50 0

    if [ -f "$pid_file" ] && kill -0 $(cat "$pid_file") 2>/dev/null; then
        log "SUCCESS: $vm started."
        whiptail --msgbox "SUCCESS: VM Started.\n\nSSH Port: $PORT\nUser: $USER\n\nWait 30s for SSH keys to generate." 12 60
    else
        local err_msg=$(cat "$qemu_err")
        whiptail --title "START FAILED" --msgbox "VM failed to start.\n\nQEMU Error:\n$err_msg" 20 70
    fi
}

# --- Logic: Connect (The Fix) ---
connect_vm_logic() {
    local vm=$1
    source "$CONFIG_DIR/$vm.conf"
    
    # Retrieve password hint if available
    local pass_hint=$(grep "#PWD_HINT=" "$CONFIG_DIR/$vm.conf" | cut -d'=' -f2)
    
    # 1. Check if VM process is alive
    local pid_file="$VM_DIR/$vm.pid"
    if [ ! -f "$pid_file" ] || ! kill -0 $(cat "$pid_file") 2>/dev/null; then
        whiptail --msgbox "VM is not running!" 8 40
        return
    fi

    # 2. Wait for Port (The Fix)
    # We loop for 5 seconds checking if the host port is listening
    local port_ready=0
    for i in {1..5}; do
        if netstat -tuln | grep -q ":$PORT "; then
            port_ready=1
            break
        fi
        sleep 1
    done

    if [ $port_ready -eq 0 ]; then
        whiptail --msgbox "VM process is running, but SSH port $PORT is not open yet.\nIt is likely still booting.\n\nTry again in 30 seconds." 12 60
        return
    fi

    clear
    echo "==============================================="
    echo "Connecting to VM: $VM_NAME"
    echo "User: $USER"
    if [ ! -z "$pass_hint" ]; then
        echo "Password: $pass_hint"
    fi
    echo "==============================================="
    echo "NOTE: If Connection Refused, wait 10s and try again."
    echo "==============================================="
    
    # 3. Connection
    # We use 127.0.0.1 explicitly to match the QEMU mapping
    # We reduce ConnectTimeout so it doesn't hang forever
    ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$USER@127.0.0.1"
    
    echo
    read -p "Connection closed. Press Enter to return..."
}

# --- Logic: Stop ---
stop_vm_logic() {
    local vm=$1
    local pid_file="$VM_DIR/$vm.pid"
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        kill "$pid" 2>/dev/null
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid"; fi
        rm -f "$pid_file"
        whiptail --msgbox "VM Stopped." 8 40
    else
        whiptail --msgbox "VM is not running." 8 40
    fi
}

# --- Logic: Delete ---
delete_vm_logic() {
    local vm=$1
    if (whiptail --title "Delete" --yesno "Delete $vm forever?" 8 40); then
        stop_vm_logic "$vm" >/dev/null 2>&1
        source "$CONFIG_DIR/$vm.conf"
        rm -f "$CONFIG_DIR/$vm.conf" "$DISK" "$SEED" "$VM_DIR/$vm.pid" "$VM_DIR/$vm.log" "$VM_DIR/$vm.console.log" "$VM_DIR/$vm.qemu.err"
        log "Deleted VM $vm"
        whiptail --msgbox "Deleted." 8 40
    fi
}

# --- Logic: View Logs ---
view_logs() {
    if [ -f "$GLOBAL_LOG" ]; then
        whiptail --title "System Log" --textbox "$GLOBAL_LOG" 20 80 --scrolltext
    else
        whiptail --msgbox "No logs found." 8 40
    fi
}

# --- Menu Loop ---
main_menu() {
    init_system
    check_install
    # check_version # Uncomment if you have a real URL
    
    while true; do
        local options=()
        options+=("NEW" "Create New VM")
        options+=("LOGS" "View System Logs")
        
        if compgen -G "$CONFIG_DIR/*.conf" > /dev/null; then
            for f in "$CONFIG_DIR"/*.conf; do
                local vm=$(basename "$f" .conf)
                local stat="OFF"
                if [ -f "$VM_DIR/$vm.pid" ] && kill -0 $(cat "$VM_DIR/$vm.pid") 2>/dev/null; then
                    stat="ON "
                fi
                options+=("$vm" "[$stat] Manage")
            done
        fi

        local choice=$(whiptail --title "$APP_TITLE" --menu "Main Menu (v$CURRENT_VERSION)" 20 60 10 "${options[@]}" 3>&1 1>&2 2>&3)
        
        case $choice in
            "NEW") create_new_vm ;;
            "LOGS") view_logs ;;
            "") exit 0 ;;
            *) 
                local action=$(whiptail --title "$choice" --menu "Action" 15 50 5 \
                    "1" "Start" "2" "Stop" "3" "SSH Connect" "4" "Delete" 3>&1 1>&2 2>&3)
                case $action in
                    1) start_vm_logic "$choice" ;;
                    2) stop_vm_logic "$choice" ;;
                    3) connect_vm_logic "$choice" ;;
                    4) delete_vm_logic "$choice" ;;
                esac
                ;;
        esac
    done
}

main_menu

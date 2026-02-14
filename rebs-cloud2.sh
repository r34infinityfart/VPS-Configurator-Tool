#!/bin/bash
# ==============================================================================
# REBS CLOUD OPS - STABLE EDITION (v3.1)
# ==============================================================================

# Strict mode
set -u

# --- Configuration ---
APP_TITLE="Rebs Cloud Ops v3.1"
BASE_DIR="$HOME/.rebs-cloud"
CONFIG_DIR="$BASE_DIR/configs"
IMG_DIR="$BASE_DIR/images"
VM_DIR="$BASE_DIR/instances"
GLOBAL_LOG="$BASE_DIR/manager.log"

# --- Initialization ---
init_system() {
    mkdir -p "$CONFIG_DIR" "$IMG_DIR" "$VM_DIR"
    
    # Check for Whiptail
    if ! command -v whiptail &> /dev/null; then
        echo "Installing UI (whiptail)..."
        sudo apt-get update && sudo apt-get install -y whiptail
    fi

    # Check for QEMU/Cloud-Utils
    local deps=("qemu-system-x86_64" "qemu-img" "cloud-localds" "wget" "netstat")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then missing+=("$dep"); fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        if (whiptail --title "Missing Dependencies" --yesno "Required tools missing: ${missing[*]}\n\nInstall them now?" 10 60); then
            sudo apt-get update
            # net-tools provides netstat
            sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils wget net-tools
        else
            echo "Cannot proceed without dependencies."
            exit 1
        fi
    fi
}

# --- UI: Create New VM ---
create_new_vm() {
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

    local ram_size=$(whiptail --inputbox "RAM (MB):" 8 40 "1024" 3>&1 1>&2 2>&3)
    local cpu_core=$(whiptail --inputbox "CPU Cores:" 8 40 "1" 3>&1 1>&2 2>&3)
    local disk_size=$(whiptail --inputbox "Disk Size:" 8 40 "10G" 3>&1 1>&2 2>&3)
    local ssh_port=$(whiptail --inputbox "SSH Port (Host):" 8 40 "2222" 3>&1 1>&2 2>&3)
    local user=$(whiptail --inputbox "Username:" 8 40 "root" 3>&1 1>&2 2>&3)
    local pass=$(whiptail --passwordbox "Password:" 8 40 3>&1 1>&2 2>&3)

    {
        echo "10"; sleep 0.5
        if [ ! -f "$IMG_DIR/$img_name" ]; then
            wget -q "$img_url" -O "$IMG_DIR/$img_name"
        fi
        echo "50"
        
        local vm_disk="$VM_DIR/$vm_name.qcow2"
        qemu-img create -f qcow2 -F qcow2 -b "$IMG_DIR/$img_name" "$vm_disk" "$disk_size" > /dev/null
        
        local seed_iso="$VM_DIR/$vm_name-seed.iso"
        local user_data=$(mktemp)
        local meta_data=$(mktemp)
        local pass_hash=$(openssl passwd -6 "$pass")

        # Cloud-Init Config
        cat > "$user_data" <<EOF
#cloud-config
hostname: $vm_name
users:
  - name: $user
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo, wheel
    shell: /bin/bash
    passwd: $pass_hash
    lock_passwd: false
ssh_pwauth: true
chpasswd:
  list: |
    root:$pass
  expire: false
runcmd:
  - systemctl start qemu-guest-agent
EOF
        echo "instance-id: $vm_name" > "$meta_data"
        echo "local-hostname: $vm_name" >> "$meta_data"
        
        cloud-localds "$seed_iso" "$user_data" "$meta_data"
        rm "$user_data" "$meta_data"
        echo "90"

        # Save absolute paths to config
        cat > "$CONFIG_DIR/$vm_name.conf" <<EOF
VM_NAME="$vm_name"
RAM="$ram_size"
CPU="$cpu_core"
DISK="$vm_disk"
SEED="$seed_iso"
PORT="$ssh_port"
USER="$user"
EOF
        echo "100"
    } | whiptail --gauge "Provisioning $vm_name..." 6 50 0
    
    whiptail --msgbox "Provisioning Complete." 8 40
}

# --- Logic: Start VM (FIXED) ---
start_vm_logic() {
    local vm=$1
    source "$CONFIG_DIR/$vm.conf"
    local pid_file="$VM_DIR/$vm.pid"
    local log_file="$VM_DIR/$vm.log"

    # 1. Check if files exist
    if [ ! -f "$DISK" ] || [ ! -f "$SEED" ]; then
        whiptail --msgbox "Error: Disk or Seed image missing!\n$DISK" 10 60
        return
    fi

    # 2. Check Port
    if netstat -tuln | grep -q ":$PORT "; then
        whiptail --msgbox "Error: Port $PORT is already in use by another process." 8 50
        return
    fi

    # 3. Determine Acceleration
    local accel_args=""
    if [ -w /dev/kvm ]; then
        accel_args="-enable-kvm -cpu host"
    else
        accel_args="-accel tcg -cpu qemu64" # Software fallback
    fi

    # 4. Attempt Start
    # We use -daemonize BUT we direct output to a log file to catch errors
    qemu-system-x86_64 \
        -name "$VM_NAME" \
        $accel_args \
        -m "$RAM" \
        -smp "$CPU" \
        -drive file="$DISK",if=virtio,format=qcow2 \
        -drive file="$SEED",if=virtio,format=raw,media=cdrom \
        -netdev user,id=n1,hostfwd=tcp::$PORT-:22 \
        -device virtio-net-pci,netdev=n1 \
        -nographic \
        -serial file:"$log_file" \
        -monitor none \
        -daemonize \
        -pidfile "$pid_file"

    # 5. Verification (Sleep briefly to see if it crashes immediately)
    {
        echo "10"
        sleep 2
        echo "50"
        if [ -f "$pid_file" ] && kill -0 $(cat "$pid_file") 2>/dev/null; then
            echo "100"
        else
            echo "0"
        fi
    } | whiptail --gauge "Starting VM..." 6 50 0

    # 6. Result Check
    if [ -f "$pid_file" ] && kill -0 $(cat "$pid_file") 2>/dev/null; then
        whiptail --msgbox "SUCCESS: VM Started.\n\nSSH Port: $PORT\n\nWait 20-30 seconds for boot before connecting." 10 60
    else
        local err_log=$(tail -n 10 "$log_file")
        whiptail --title "START FAILED" --msgbox "The VM failed to start.\n\nLast Log Output:\n$err_log" 15 70
    fi
}

# --- Logic: Connect ---
connect_vm_logic() {
    local vm=$1
    source "$CONFIG_DIR/$vm.conf"
    
    if ! netstat -tuln | grep -q ":$PORT "; then
        whiptail --msgbox "VM is running, but SSH port ($PORT) is not listening yet.\n\nIt might still be booting. Try again in 10 seconds." 10 60
        return
    fi

    clear
    echo "Connecting to $vm on port $PORT..."
    ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@localhost"
    read -p "Press Enter to return..."
}

# --- Logic: Stop ---
stop_vm_logic() {
    local vm=$1
    local pid_file="$VM_DIR/$vm.pid"
    if [ -f "$pid_file" ]; then
        kill $(cat "$pid_file")
        rm "$pid_file"
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
        rm -f "$CONFIG_DIR/$vm.conf" "$DISK" "$SEED" "$VM_DIR/$vm.pid" "$VM_DIR/$vm.log"
        whiptail --msgbox "Deleted." 8 40
    fi
}

# --- Menu Loop ---
main_menu() {
    init_system
    while true; do
        local options=()
        options+=("NEW" "Create New VM")
        
        for f in "$CONFIG_DIR"/*.conf; do
            if [ -e "$f" ]; then
                local vm=$(basename "$f" .conf)
                local stat="OFF"
                [ -f "$VM_DIR/$vm.pid" ] && kill -0 $(cat "$VM_DIR/$vm.pid") 2>/dev/null && stat="ON "
                options+=("$vm" "[$stat] Manage")
            fi
        done

        local choice=$(whiptail --title "$APP_TITLE" --menu "Main Menu" 20 60 10 "${options[@]}" 3>&1 1>&2 2>&3)
        
        case $choice in
            "NEW") create_new_vm ;;
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

#!/bin/bash
# ==============================================================================
# REBS CLOUD MANAGER PRO - v2.6 (2026 Edition)
# Professional QEMU/KVM Virtualization Wrapper for Debian/Ubuntu Systems
# ==============================================================================

set -uo pipefail

# --- Configuration & Constants ---
APP_NAME="Rebs Cloud Manager"
VERSION="2.6.0"
BASE_DIR="$HOME/.local/share/rebs-cloud"
CONFIG_DIR="$HOME/.config/rebs-cloud"
IMG_DIR="$BASE_DIR/images"
VM_DIR="$BASE_DIR/instances"
LOG_FILE="$BASE_DIR/manager.log"

# Colors
C_RESET='\033[0m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[1;34m'
C_CYAN='\033[1;36m'
C_GRAY='\033[1;90m'

# --- Initialization ---
mkdir -p "$IMG_DIR" "$VM_DIR" "$CONFIG_DIR"
touch "$LOG_FILE"

# --- Helper Functions ---

log() {
    local level=$1
    local msg=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

print_msg() {
    local type=$1
    local msg=$2
    case $type in
        "INFO") echo -e "${C_BLUE}ℹ  INFO:${C_RESET} $msg" ;;
        "SUCCESS") echo -e "${C_GREEN}✔  SUCCESS:${C_RESET} $msg" ;;
        "WARN") echo -e "${C_YELLOW}⚠  WARNING:${C_RESET} $msg" ;;
        "ERROR") echo -e "${C_RED}✖  ERROR:${C_RESET} $msg" ;;
        "INPUT") echo -ne "${C_CYAN}➤  $msg${C_RESET} " ;;
        "HEADER") echo -e "\n${C_BLUE}=== $msg ===${C_RESET}" ;;
    esac
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "qemu-img" "cloud-localds" "wget" "genisoimage")
    local missing=()
    
    # Check specifically for cloud-localds provider
    if ! command -v cloud-localds &> /dev/null; then
        missing+=("cloud-image-utils")
    fi

    if ! command -v qemu-system-x86_64 &> /dev/null; then
        missing+=("qemu-system-x86")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        print_msg "WARN" "Missing dependencies: ${missing[*]}"
        read -p "$(echo -e "${C_CYAN}➤  Attempt to install via apt? (y/n): ${C_RESET}")" install_opt
        if [[ "$install_opt" =~ ^[Yy]$ ]]; then
            sudo apt-get update && sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils wget genisoimage
        else
            print_msg "ERROR" "Cannot proceed without dependencies."
            exit 1
        fi
    fi
}

check_kvm() {
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ACCEL_FLAGS="-enable-kvm -cpu host"
        print_msg "SUCCESS" "KVM Hardware Acceleration detected."
    else
        ACCEL_FLAGS="-accel tcg -cpu qemu64"
        print_msg "WARN" "KVM not detected/writable. Using software emulation (Slow)."
    fi
}

# --- Core VM Logic ---

get_vm_config() {
    local vm_name=$1
    local config_file="$CONFIG_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        return 0
    fi
    return 1
}

is_vm_running() {
    local vm_name=$1
    local pid_file="$VM_DIR/$vm_name.pid"
    
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            if ps -p "$pid" -o cmd= | grep -q "$vm_name"; then
                return 0
            fi
        fi
        # Stale PID file
        rm -f "$pid_file"
    fi
    return 1
}

create_vm() {
    clear
    print_msg "HEADER" "Create New Virtual Machine"

    # 1. Select OS (Updated for 2026)
    echo -e "${C_GRAY}Select Operating System:${C_RESET}"
    local os_names=("Ubuntu 24.04 LTS (Noble)" "Ubuntu 22.04 LTS (Jammy)" "Debian 13 (Trixie)" "Debian 12 (Bookworm)" "AlmaLinux 9" "Rocky Linux 9")
    local os_urls=(
        "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
        "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
        "https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2"
        "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
        "https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
        "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
    )

    select opt in "${os_names[@]}"; do
        if [[ -n "$opt" ]]; then
            local idx=$((REPLY-1))
            IMG_URL="${os_urls[$idx]}"
            OS_NAME="$opt"
            break
        fi
    done

    # 2. Configuration
    print_msg "INPUT" "VM Name (no spaces):"
    read VM_NAME
    [[ "$VM_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { print_msg "ERROR" "Invalid name."; return; }
    
    if [[ -f "$CONFIG_DIR/$VM_NAME.conf" ]]; then print_msg "ERROR" "VM exists."; return; fi

    print_msg "INPUT" "RAM (MB) [2048]:"
    read MEMORY
    MEMORY=${MEMORY:-2048}

    print_msg "INPUT" "CPUs [2]:"
    read CPUS
    CPUS=${CPUS:-2}

    print_msg "INPUT" "Disk Size (e.g., 20G) [20G]:"
    read DISK_SIZE
    DISK_SIZE=${DISK_SIZE:-20G}

    print_msg "INPUT" "SSH Port [2222]:"
    read SSH_PORT
    SSH_PORT=${SSH_PORT:-2222}

    print_msg "INPUT" "Username [rebsuser]:"
    read USERNAME
    USERNAME=${USERNAME:-rebsuser}

    print_msg "INPUT" "Password:"
    read -s PASSWORD
    echo ""

    # 3. Preparation
    local vm_img="$VM_DIR/$VM_NAME.qcow2"
    local seed_iso="$VM_DIR/$VM_NAME-seed.iso"
    local base_img="$IMG_DIR/$(basename "$IMG_URL")"

    # Download Base Image if missing
    if [[ ! -f "$base_img" ]]; then
        print_msg "INFO" "Downloading Base Image ($OS_NAME)..."
        wget -q --show-progress "$IMG_URL" -O "$base_img"
    fi

    # Create Copy On Write (COW) image - Saves space
    print_msg "INFO" "Creating Disk Image..."
    qemu-img create -f qcow2 -F qcow2 -b "$base_img" "$vm_img" "$DISK_SIZE" > /dev/null

    # Cloud-Init Config
    print_msg "INFO" "Generating Cloud-Init Config..."
    local user_data=$(mktemp)
    local meta_data=$(mktemp)
    
    # Hash password safely
    local pass_hash=$(openssl passwd -6 "$PASSWORD")

    cat > "$user_data" <<EOF
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo, wheel
    shell: /bin/bash
    lock_passwd: false
    passwd: $pass_hash
ssh_pwauth: true
package_update: true
packages:
  - qemu-guest-agent
  - htop
  - curl
runcmd:
  - systemctl start qemu-guest-agent
EOF

    echo "instance-id: $VM_NAME" > "$meta_data"
    echo "local-hostname: $VM_NAME" >> "$meta_data"

    cloud-localds "$seed_iso" "$user_data" "$meta_data"
    rm -f "$user_data" "$meta_data"

    # Save Config
    cat > "$CONFIG_DIR/$VM_NAME.conf" <<EOF
VM_NAME="$VM_NAME"
OS_NAME="$OS_NAME"
MEMORY="$MEMORY"
CPUS="$CPUS"
DISK_SIZE="$DISK_SIZE"
SSH_PORT="$SSH_PORT"
USERNAME="$USERNAME"
IMG_FILE="$vm_img"
SEED_FILE="$seed_iso"
CREATED="$(date)"
EOF

    print_msg "SUCCESS" "VM '$VM_NAME' created. Ready to start."
    log "INFO" "Created VM $VM_NAME"
    read -p "Press Enter to continue..."
}

start_vm() {
    local vm_name=$1
    get_vm_config "$vm_name" || return 1

    if is_vm_running "$vm_name"; then
        print_msg "WARN" "VM is already running."
        return
    fi

    print_msg "INFO" "Starting $vm_name (Port: $SSH_PORT)..."

    # Construct QEMU Command
    # We use -daemonize to run in background properly
    qemu-system-x86_64 \
        -name "$VM_NAME" \
        $ACCEL_FLAGS \
        -m "$MEMORY" \
        -smp "$CPUS" \
        -drive file="$IMG_FILE",if=virtio,format=qcow2 \
        -drive file="$SEED_FILE",if=virtio,format=raw,media=cdrom \
        -netdev user,id=n1,hostfwd=tcp::$SSH_PORT-:22 \
        -device virtio-net-pci,netdev=n1 \
        -vga virtio \
        -display none \
        -daemonize \
        -pidfile "$VM_DIR/$VM_NAME.pid" \
        -serial file:"$VM_DIR/$VM_NAME.log" \
        -device virtio-balloon-pci \
        -device virtio-rng-pci

    sleep 2
    if is_vm_running "$vm_name"; then
        print_msg "SUCCESS" "VM Started."
        print_msg "INFO" "Access: ssh -p $SSH_PORT $USERNAME@localhost"
    else
        print_msg "ERROR" "Failed to start. Check logs at $VM_DIR/$VM_NAME.log"
    fi
}

stop_vm() {
    local vm_name=$1
    if ! is_vm_running "$vm_name"; then
        print_msg "WARN" "VM is not running."
        return
    fi

    local pid=$(cat "$VM_DIR/$vm_name.pid")
    print_msg "INFO" "Stopping $vm_name (PID: $pid)..."
    kill "$pid"
    
    # Wait for shutdown
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        ((i++))
        if [ "$i" -gt 20 ]; then
            kill -9 "$pid"
            print_msg "WARN" "Force killed."
            break
        fi
        sleep 1
    done
    rm -f "$VM_DIR/$vm_name.pid"
    print_msg "SUCCESS" "VM Stopped."
}

manage_snapshots() {
    local vm_name=$1
    get_vm_config "$vm_name"
    
    clear
    print_msg "HEADER" "Snapshot Manager: $vm_name"
    
    if is_vm_running "$vm_name"; then
        print_msg "WARN" "VM must be stopped to manage snapshots safely."
        return
    fi

    echo "Existing Snapshots:"
    qemu-img snapshot -l "$IMG_FILE"
    echo "-------------------------"
    echo "1. Create Snapshot"
    echo "2. Revert to Snapshot"
    echo "3. Delete Snapshot"
    echo "0. Back"
    
    read -p "Choice: " snap_choice
    case $snap_choice in
        1)
            read -p "Snapshot Name: " sname
            qemu-img snapshot -c "$sname" "$IMG_FILE"
            print_msg "SUCCESS" "Snapshot created."
            ;;
        2)
            read -p "Snapshot Name to Restore: " sname
            qemu-img snapshot -a "$sname" "$IMG_FILE"
            print_msg "SUCCESS" "Restored to $sname."
            ;;
        3)
            read -p "Snapshot Name to Delete: " sname
            qemu-img snapshot -d "$sname" "$IMG_FILE"
            print_msg "SUCCESS" "Deleted $sname."
            ;;
    esac
    read -p "Press Enter..."
}

delete_vm() {
    local vm_name=$1
    print_msg "WARN" "This will permanently delete VM '$vm_name'."
    read -p "Are you sure? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        stop_vm "$vm_name" >/dev/null 2>&1
        get_vm_config "$vm_name"
        rm -f "$CONFIG_DIR/$vm_name.conf"
        rm -f "$IMG_FILE"
        rm -f "$SEED_FILE"
        rm -f "$VM_DIR/$vm_name.pid"
        rm -f "$VM_DIR/$vm_name.log"
        print_msg "SUCCESS" "VM Deleted."
    fi
}

list_vms() {
    clear
    print_msg "HEADER" "Virtual Machines"
    printf "%-5s %-20s %-10s %-10s %-10s\n" "ID" "NAME" "STATUS" "PORT" "RAM"
    echo "---------------------------------------------------------"
    
    local vms=($(find "$CONFIG_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort))
    local i=1
    
    for vm in "${vms[@]}"; do
        source "$CONFIG_DIR/$vm.conf"
        local status="${C_RED}Stopped${C_RESET}"
        if is_vm_running "$vm"; then status="${C_GREEN}Running${C_RESET}"; fi
        
        printf "%-5s %-20s %-19s %-10s %-10s\n" "$i)" "$vm" "$status" "$SSH_PORT" "${MEMORY}MB"
        ((i++))
    done
    echo ""
    return ${#vms[@]}
}

# --- Main Interface ---

check_dependencies
check_kvm

while true; do
    list_vms
    local vm_count=$?
    local vms=($(find "$CONFIG_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort))

    echo -e "${C_BLUE}Actions:${C_RESET}"
    echo "  n) New VM"
    echo "  r) Refresh List"
    echo "  x) Exit"
    
    if [ $vm_count -gt 0 ]; then
        echo -e "\n${C_BLUE}Management:${C_RESET}"
        read -p "Select VM ID to manage (or Action): " selection
    else
        read -p "Select Action: " selection
    fi

    case $selection in
        [Nn]) create_vm ;;
        [Rr]) continue ;;
        [Xx]) echo "Exiting."; exit 0 ;;
        *)
            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -le $vm_count ] && [ "$selection" -gt 0 ]; then
                local selected_vm="${vms[$((selection-1))]}"
                while true; do
                    clear
                    print_msg "HEADER" "Managing: $selected_vm"
                    is_vm_running "$selected_vm" && echo -e "Status: ${C_GREEN}RUNNING${C_RESET}" || echo -e "Status: ${C_RED}STOPPED${C_RESET}"
                    echo ""
                    echo "1) Start VM"
                    echo "2) Stop VM"
                    echo "3) Connect (SSH)"
                    echo "4) Snapshots"
                    echo "5) Resize Disk"
                    echo "6) Delete VM"
                    echo "0) Back to List"
                    
                    read -p "Action: " action
                    case $action in
                        1) start_vm "$selected_vm"; read -p "..." ;;
                        2) stop_vm "$selected_vm"; read -p "..." ;;
                        3) 
                           source "$CONFIG_DIR/$selected_vm.conf"
                           ssh -p "$SSH_PORT" "$USERNAME@localhost"
                           ;;
                        4) manage_snapshots "$selected_vm" ;;
                        5)
                           read -p "New Size (e.g. +10G): " size
                           qemu-img resize "$BASE_DIR/instances/$selected_vm.qcow2" "$size"
                           print_msg "SUCCESS" "Disk resized. Expand filesystem inside VM."
                           read -p "..."
                           ;;
                        6) delete_vm "$selected_vm"; break ;;
                        0) break ;;
                    esac
                done
            fi
            ;;
    esac
done

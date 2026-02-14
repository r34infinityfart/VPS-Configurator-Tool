#!/bin/bash
# ==============================================================================
# REBS CLOUD OPS - PROFESSIONAL EDITION (v3.0.0)
# The Ultimate Lightweight VPS Manager for Debian/Ubuntu
# ==============================================================================

# Strict mode for safety
set -u

# --- Configuration & Constants ---
APP_TITLE="Rebs Cloud Ops v3.0"
BASE_DIR="$HOME/.rebs-cloud"
CONFIG_DIR="$BASE_DIR/configs"
IMG_DIR="$BASE_DIR/images"
VM_DIR="$BASE_DIR/instances"
LOG_FILE="$BASE_DIR/system.log"

# --- Colors for non-UI output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Initialization & Dependency Check ---
init_system() {
    # 1. Directory Structure
    mkdir -p "$CONFIG_DIR" "$IMG_DIR" "$VM_DIR"
    touch "$LOG_FILE"

    # 2. Check for Whiptail (Critical for UI)
    if ! command -v whiptail &> /dev/null; then
        echo -e "${BLUE}Installing UI components (whiptail)...${NC}"
        sudo apt-get update && sudo apt-get install -y whiptail
    fi

    # 3. Check for Virtualization Tools
    local deps=("qemu-system-x86_64" "qemu-img" "cloud-localds" "wget")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    # 4. Auto-Install Dependencies
    if [ ${#missing[@]} -ne 0 ]; then
        if (whiptail --title "Missing Dependencies" --yesno "The following tools are required:\n\n${missing[*]}\n\nInstall them now?" 10 60); then
            sudo apt-get update
            sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils wget
        else
            echo -e "${RED}Cannot proceed without dependencies.${NC}"
            exit 1
        fi
    fi
}

# --- Helper: Logging ---
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# --- Helper: KVM Check ---
get_accel() {
    if [ -w /dev/kvm ]; then
        echo "-enable-kvm -cpu host"
    else
        echo "-accel tcg -cpu qemu64" # Software fallback
    fi
}

# --- UI: Create New VM ---
create_new_vm() {
    # 1. OS Selection
    local os_choice=$(whiptail --title "Select Operating System" --menu "Choose a base image:" 15 60 6 \
        "Ubuntu 24.04" "Noble Numbat LTS" \
        "Ubuntu 22.04" "Jammy Jellyfish LTS" \
        "Debian 13" "Trixie (Testing)" \
        "Debian 12" "Bookworm (Stable)" \
        "AlmaLinux 9" "Enterprise Linux" 3>&1 1>&2 2>&3)

    if [ -z "$os_choice" ]; then return; fi

    # Map Selection to URL
    local img_url=""
    local img_name=""
    case $os_choice in
        "Ubuntu 24.04") img_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"; img_name="ubuntu-24.04.img" ;;
        "Ubuntu 22.04") img_url="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"; img_name="ubuntu-22.04.img" ;;
        "Debian 13")    img_url="https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2"; img_name="debian-13.qcow2" ;;
        "Debian 12")    img_url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"; img_name="debian-12.qcow2" ;;
        "AlmaLinux 9")  img_url="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"; img_name="alma-9.qcow2" ;;
    esac

    # 2. VM Details Form
    local vm_name=$(whiptail --inputbox "Enter VM Name (no spaces):" 8 40 "my-vps-1" 3>&1 1>&2 2>&3)
    if [ -z "$vm_name" ]; then return; fi
    
    # Check if exists
    if [ -f "$CONFIG_DIR/$vm_name.conf" ]; then
        whiptail --msgbox "Error: VM '$vm_name' already exists!" 8 40
        return
    fi

    local ram_size=$(whiptail --inputbox "RAM Size (MB):" 8 40 "2048" 3>&1 1>&2 2>&3)
    local cpu_core=$(whiptail --inputbox "CPU Cores:" 8 40 "2" 3>&1 1>&2 2>&3)
    local disk_size=$(whiptail --inputbox "Disk Size (e.g. 20G):" 8 40 "20G" 3>&1 1>&2 2>&3)
    local ssh_port=$(whiptail --inputbox "SSH Port (Host):" 8 40 "2222" 3>&1 1>&2 2>&3)
    local username=$(whiptail --inputbox "Username:" 8 40 "admin" 3>&1 1>&2 2>&3)
    local password=$(whiptail --passwordbox "Password:" 8 40 3>&1 1>&2 2>&3)

    # 3. Processing (Progress Bar)
    {
        echo "10"; sleep 0.5
        
        # Download Base Image if missing
        if [ ! -f "$IMG_DIR/$img_name" ]; then
            echo "XXX"; echo "Downloading $os_choice..."; echo "XXX"
            wget -q "$img_url" -O "$IMG_DIR/$img_name"
        fi
        echo "40"

        # Create COW Image
        echo "XXX"; echo "Creating Disk Structure..."; echo "XXX"
        local vm_disk="$VM_DIR/$vm_name.qcow2"
        qemu-img create -f qcow2 -F qcow2 -b "$IMG_DIR/$img_name" "$vm_disk" "$disk_size" > /dev/null
        echo "60"

        # Create Cloud-Init Seed
        echo "XXX"; echo "Generating Cloud Configuration..."; echo "XXX"
        local seed_iso="$VM_DIR/$vm_name-seed.iso"
        local user_data=$(mktemp)
        local meta_data=$(mktemp)
        local pass_hash=$(openssl passwd -6 "$password")

        cat > "$user_data" <<EOF
#cloud-config
hostname: $vm_name
manage_etc_hosts: true
users:
  - name: $username
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo, wheel
    shell: /bin/bash
    passwd: $pass_hash
    lock_passwd: false
ssh_pwauth: true
package_update: true
packages:
  - qemu-guest-agent
  - htop
  - curl
runcmd:
  - systemctl start qemu-guest-agent
EOF
        echo "instance-id: $vm_name" > "$meta_data"
        echo "local-hostname: $vm_name" >> "$meta_data"
        
        cloud-localds "$seed_iso" "$user_data" "$meta_data"
        rm "$user_data" "$meta_data"
        echo "80"

        # Save Config
        cat > "$CONFIG_DIR/$vm_name.conf" <<EOF
VM_NAME="$vm_name"
OS_TYPE="$os_choice"
RAM="$ram_size"
CPU="$cpu_core"
DISK="$vm_disk"
SEED="$seed_iso"
PORT="$ssh_port"
USER="$username"
CREATED="$(date)"
EOF
        echo "100"
        sleep 1
    } | whiptail --gauge "Provisioning VM..." 6 50 0

    whiptail --msgbox "VM '$vm_name' Created Successfully!\n\nYou can now start it from the main menu." 10 60
}

# --- Logic: Start VM ---
start_vm_logic() {
    local vm=$1
    source "$CONFIG_DIR/$vm.conf"
    
    local pid_file="$VM_DIR/$vm.pid"
    
    # Check if running
    if [ -f "$pid_file" ]; then
        if kill -0 $(cat "$pid_file") 2>/dev/null; then
            whiptail --msgbox "VM is already running!" 8 40
            return
        fi
        rm "$pid_file" # Remove stale pid
    fi

    local accel=$(get_accel)
    
    # QEMU Command - The Engine
    qemu-system-x86_64 \
        -name "$VM_NAME" \
        $accel \
        -m "$RAM" \
        -smp "$CPU" \
        -drive file="$DISK",if=virtio,format=qcow2 \
        -drive file="$SEED",if=virtio,format=raw,media=cdrom \
        -netdev user,id=n1,hostfwd=tcp::$PORT-:22 \
        -device virtio-net-pci,netdev=n1 \
        -display none \
        -daemonize \
        -pidfile "$pid_file" \
        -device virtio-balloon-pci \
        -device virtio-rng-pci

    if [ $? -eq 0 ]; then
        whiptail --msgbox "VM Started!\n\nConnect via:\nssh -p $PORT $USER@localhost" 12 50
    else
        whiptail --msgbox "Failed to start VM. Check logs." 8 40
    fi
}

# --- Logic: Stop VM ---
stop_vm_logic() {
    local vm=$1
    local pid_file="$VM_DIR/$vm.pid"
    
    if [ ! -f "$pid_file" ]; then
        whiptail --msgbox "VM is not running." 8 40
        return
    fi

    local pid=$(cat "$pid_file")
    kill "$pid"
    rm "$pid_file"
    whiptail --msgbox "VM Stopped." 8 40
}

# --- Logic: Delete VM ---
delete_vm_logic() {
    local vm=$1
    if (whiptail --title "Confirm Deletion" --yesno "Are you SURE you want to delete '$vm'?\nThis cannot be undone." 10 60); then
        # Stop first
        local pid_file="$VM_DIR/$vm.pid"
        if [ -f "$pid_file" ]; then kill $(cat "$pid_file") 2>/dev/null; rm "$pid_file"; fi
        
        # Source to get paths
        source "$CONFIG_DIR/$vm.conf"
        
        # Delete files
        rm -f "$CONFIG_DIR/$vm.conf"
        rm -f "$DISK"
        rm -f "$SEED"
        
        whiptail --msgbox "VM Deleted." 8 40
    fi
}

# --- Logic: Connect VM ---
connect_vm_logic() {
    local vm=$1
    source "$CONFIG_DIR/$vm.conf"
    
    # We need to clear screen for SSH
    clear
    echo -e "${GREEN}Connecting to $VM_NAME...${NC}"
    echo -e "Use password set during creation."
    echo -e "Type 'exit' to return to menu."
    echo "-----------------------------------"
    ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@localhost"
    
    # Pause before returning to menu
    echo "-----------------------------------"
    read -p "Press Enter to return to menu..."
}

# --- UI: Manage Specific VM ---
manage_vm_menu() {
    local vm=$1
    while true; do
        local status="STOPPED"
        if [ -f "$VM_DIR/$vm.pid" ] && kill -0 $(cat "$VM_DIR/$vm.pid") 2>/dev/null; then
            status="RUNNING"
        fi

        local action=$(whiptail --title "Manage: $vm" --menu "Status: $status" 15 60 5 \
            "1" "Start VM" \
            "2" "Stop VM" \
            "3" "Connect (SSH)" \
            "4" "Delete VM" \
            "B" "Back to Main Menu" 3>&1 1>&2 2>&3)

        case $action in
            1) start_vm_logic "$vm" ;;
            2) stop_vm_logic "$vm" ;;
            3) connect_vm_logic "$vm" ;;
            4) delete_vm_logic "$vm"; break ;;
            "B"|*) break ;;
        esac
    done
}

# --- Main Loop ---
main_menu() {
    init_system

    while true; do
        # Build VM List for Menu
        local vm_files=("$CONFIG_DIR"/*.conf)
        local menu_items=()
        
        # If no VMs found
        if [ ! -e "${vm_files[0]}" ]; then
            menu_items+=("NEW" "Create New VM")
        else
            menu_items+=("NEW" "Create New VM")
            for f in "${vm_files[@]}"; do
                local name=$(basename "$f" .conf)
                # Check status for label
                local label="$name"
                if [ -f "$VM_DIR/$name.pid" ] && kill -0 $(cat "$VM_DIR/$name.pid") 2>/dev/null; then
                    label="$name [ON]"
                else
                    label="$name [OFF]"
                fi
                menu_items+=("$name" "$label")
            done
        fi

        # Display Main Menu
        local choice=$(whiptail --title "$APP_TITLE" --menu "Manage your Cloud Environment" 20 70 10 \
            "${menu_items[@]}" \
            "EXIT" "Quit" 3>&1 1>&2 2>&3)

        case $choice in
            "NEW") create_new_vm ;;
            "EXIT"|*) clear; exit 0 ;;
            *) manage_vm_menu "$choice" ;;
        esac
    done
}

# Start the application
main_menu

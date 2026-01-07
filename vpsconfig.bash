#!/bin/bash

# ==============================================================================
#  REBS VPS CONFIGURATOR - DEBIAN 11
#  High-performance configuration utility
# ==============================================================================

# --- Visual Configuration ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\133[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Utility Functions ---

# Ensure script is run as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ This script must be run as root.${NC}"
        exit 1
    fi
}

# Draw a centered horizontal line
draw_line() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Professional Banner Generator
draw_header() {
    clear
    local title="$1"
    draw_line
    echo -e "${PURPLE}"
cat << "EOF"
  ____      _             
 |  _ \ ___| |__  ___   
 | |_) / _ \ '_ \/ __|  
 |  _ <  __/ |_) \__ \  
 |_| \_\___|_.__/|___/  
EOF
    echo -e "${NC}"
    echo -e "${CYAN}   VPS CONFIGURATION UTILITY${NC}"
    echo -e "${NC}   Current Module: ${WHITE}${BOLD}$title${NC}"
    draw_line
    echo ""
}

# Status Messages
log_info() { echo -e "${CYAN}ℹ️  $1${NC}"; }
log_process() { echo -e "${YELLOW}⏳ $1...${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_warning() { echo -e "${PURPLE}⚠️  $1${NC}"; }

# Check and Install Dependencies
check_dependencies() {
    local dependencies=("curl" "wget" "sudo" "gnupg" "lsb-release" "ca-certificates")
    local install_needed=false

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            install_needed=true
            break
        fi
    done

    if [ "$install_needed" = true ]; then
        log_process "Installing system dependencies"
        apt-get update -qq && apt-get install -y -qq "${dependencies[@]}" >/dev/null 2>&1
        log_success "Dependencies installed"
    fi
}

# Pause function
pause() {
    echo ""
    read -p "$(echo -e "${WHITE}Press ${CYAN}[ENTER]${WHITE} to return to menu...${NC}")"
}

# Remote Script Runner (Robust)
run_remote() {
    local url=$1
    local name=$2
    
    draw_header "$name"
    log_process "Fetching resources..."

    local temp_script=$(mktemp)
    
    # Attempt download with visual progress
    if curl -fsSL "$url" -o "$temp_script"; then
        log_success "Resource acquired"
        chmod +x "$temp_script"
        
        echo -e "${WHITE}Executing script...${NC}\n"
        bash "$temp_script"
        local status=$?
        
        rm -f "$temp_script"
        
        if [ $status -eq 0 ]; then
            log_success "$name completed successfully."
        else
            log_error "$name exited with errors (Code: $status)."
        fi
    else
        log_error "Failed to download remote script from source."
        log_warning "Please check your internet connection or DNS settings."
    fi
    pause
}

# --- Module Functions ---

action_system_info() {
    draw_header "SYSTEM ANALYTICS"
    
    local os_info=$(lsb_release -ds 2>/dev/null || cat /etc/*release 2>/dev/null | head -n1 || uname -om)
    local kernel=$(uname -r)
    local uptime=$(uptime -p | sed 's/up //')
    local load=$(cat /proc/loadavg | awk '{print $1", "$2", "$3}')
    local memory=$(free -h | awk '/Mem:/ {print $3 " used / " $2 " total"}')
    local disk=$(df -h / | awk 'NR==2 {print $3 " used / " $2 " total ("$5")"}')
    local ip_addr=$(hostname -I | awk '{print $1}')

    echo -e "${WHITE}┌────────────────────────────────────────────────────────┐${NC}"
    echo -e "${WHITE}│  ${BOLD}OS Distro${NC}      : ${CYAN}$os_info${NC}"
    echo -e "${WHITE}│  ${BOLD}Kernel${NC}         : ${CYAN}$kernel${NC}"
    echo -e "${WHITE}│  ${BOLD}Uptime${NC}         : ${CYAN}$uptime${NC}"
    echo -e "${WHITE}│  ${BOLD}Load Avg${NC}       : ${CYAN}$load${NC}"
    echo -e "${WHITE}│  ${BOLD}Memory${NC}         : ${CYAN}$memory${NC}"
    echo -e "${WHITE}│  ${BOLD}Disk Usage${NC}     : ${CYAN}$disk${NC}"
    echo -e "${WHITE}│  ${BOLD}Internal IP${NC}    : ${CYAN}$ip_addr${NC}"
    echo -e "${WHITE}└────────────────────────────────────────────────────────┘${NC}"
    pause
}

action_tailscale() {
    draw_header "TAILSCALE VPN"
    log_process "Initializing installation..."
    
    if curl -fsSL https://tailscale.com/install.sh | sh; then
        log_success "Tailscale package installed"
        systemctl enable --now tailscaled >/dev/null 2>&1
        
        echo ""
        echo -e "${WHITE}Authenticating...${NC}"
        
        if [ -n "${TS_AUTH_KEY:-}" ]; then
            sudo tailscale up --auth-key="$TS_AUTH_KEY" && log_success "Authenticated via Pre-shared Key"
        else
            sudo tailscale up
        fi
        
        echo ""
        log_success "Tailscale is active!"
    else
        log_error "Installation failed"
    fi
    pause
}

action_database() {
    draw_header "DATABASE CONFIGURATION"
    log_info "This tool creates a MySQL/MariaDB user with global access."
    
    echo -e "${WHITE}Please provide credentials:${NC}"
    read -p "$(echo -e "${CYAN}  Username: ${NC}")" DB_USER
    read -sp "$(echo -e "${CYAN}  Password: ${NC}")" DB_PASS
    echo ""
    
    if [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
        log_error "Username or password cannot be empty."
        pause
        return
    fi

    log_process "Configuring database permissions"

    # Safely execute SQL
    mysql -u root -p$(cat /etc/mysql/debian.cnf 2>/dev/null | grep password | head -n 1 | awk '{print $3}' || echo "") -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}'; GRANT ALL PRIVILEGES ON *.* TO '${DB_USER}'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null
    
    # Handle Bind Address
    local CONF_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf"
    if [ -f "$CONF_FILE" ]; then
        read -p "$(echo -e "${YELLOW}  Expose database to internet (0.0.0.0)? [y/N]: ${NC}")" expose_choice
        if [[ "$expose_choice" =~ ^[Yy]$ ]]; then
             sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "$CONF_FILE"
             log_success "Remote access enabled in config"
        fi
    fi

    systemctl restart mysql mariadb 2>/dev/null
    
    # Firewall
    if command -v ufw &>/dev/null; then
        ufw allow 3306/tcp >/dev/null 2>&1
    fi

    log_success "User '$DB_USER' configured successfully."
    pause
}

action_blueprints() {
    draw_header "PTERODACTYL EXTENSIONS"
    log_warning "This will install third-party blueprints."
    log_info "Targeting: /var/www/pterodactyl"
    
    if [ ! -d "/var/www/pterodactyl" ]; then
        log_error "Pterodactyl directory not found."
        pause
        return
    fi

    cd /var/www/pterodactyl || return
    
    log_process "Downloading definitions..."
    wget -q -O minecraftplayermanager.blueprint https://github.com/NotJishnuisback/Free123/raw/refs/heads/main/minecraftplayermanager.blueprint
    wget -q -O mcplugins.blueprint https://github.com/NotJishnuisback/Free123/raw/refs/heads/main/mcplugins.blueprint
    
    if command -v blueprint &>/dev/null; then
        log_process "Installing MC Plugins Blueprint..."
        blueprint -i mcplugins.blueprint
        echo ""
        log_process "Installing Player Manager Blueprint..."
        blueprint -i minecraftplayermanager.blueprint
        log_success "Installation routine finished."
    else
        log_error "'blueprint' command not found. Install the framework first."
    fi
    pause
}

# --- Main Logic ---

check_root
check_dependencies

while true; do
    draw_header "MAIN MENU"
    
    echo -e "${WHITE}  Panel Management:${NC}"
    echo -e "  ${CYAN}[1]${NC} Install Panel"
    echo -e "  ${CYAN}[2]${NC} Install Wings"
    echo -e "  ${CYAN}[3]${NC} Update Panel"
    echo -e "  ${CYAN}[4]${NC} Uninstall Tools"
    echo ""
    echo -e "${WHITE}  Configuration:${NC}"
    echo -e "  ${CYAN}[5]${NC} Blueprint Framework Setup"
    echo -e "  ${CYAN}[6]${NC} Blueprint Extensions (Plugins/Manager)"
    echo -e "  ${CYAN}[7]${NC} Cloudflare Tunnel"
    echo -e "  ${CYAN}[8]${NC} Change Panel Theme"
    echo -e "  ${CYAN}[9]${NC} Database Setup (Remote Access)"
    echo ""
    echo -e "${WHITE}  System:${NC}"
    echo -e "  ${CYAN}[10]${NC} Install Tailscale"
    echo -e "  ${CYAN}[11]${NC} System Analytics"
    echo ""
    echo -e "  ${RED}[0]${NC} Exit"
    
    draw_line
    echo -e "${WHITE}Enter your selection below:${NC}"
    read -p "root@rebs:~# " choice

    case $choice in
        1) run_remote "https://raw.githubusercontent.com/JishnuTheGamer/Vps/refs/heads/main/cd/panel2.sh" "Panel Installation" ;;
        2) run_remote "https://raw.githubusercontent.com/r34infinityfart/vps/refs/heads/main/wings.sh" "Wings Installation" ;;
        3) run_remote "https://raw.githubusercontent.com/JishnuTheGamer/Vps/refs/heads/main/cd/update2.sh" "Panel Update" ;;
        4) run_remote "https://raw.githubusercontent.com/JishnuTheGamer/Vps/refs/heads/main/cd/uninstall2.sh" "Uninstaller" ;;
        5) run_remote "https://raw.githubusercontent.com/JishnuTheGamer/Vps/refs/heads/main/cd/Blueprint2.sh" "Blueprint Framework" ;;
        6) action_blueprints ;;
        7) run_remote "https://raw.githubusercontent.com/JishnuTheGamer/Vps/refs/heads/main/cd/cloudflare.sh" "Cloudflare Tunnel" ;;
        8) run_remote "https://raw.githubusercontent.com/JishnuTheGamer/Vps/refs/heads/main/cd/th2.sh" "Theme Installer" ;;
        9) action_database ;;
        10) action_tailscale ;;
        11) action_system_info ;;
        0) 
            clear
            echo -e "${CYAN}Thanks for using Rebs Configurator.${NC}"
            exit 0 
            ;;
        *) 
            log_error "Invalid selection."
            sleep 1
            ;;
    esac
done

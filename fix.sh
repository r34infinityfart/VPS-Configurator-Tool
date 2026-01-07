#!/bin/bash

# ==============================================================================
#  REBS AUTOMATED REPAIR & CONFIGURATOR
#  Fixes: 500 Errors, Permissions, and Cloudflare SSL Mismatches
# ==============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\133[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Check Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ Please run as root.${NC}"
   exit 1
fi

clear
echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   ${CYAN}PTERODACTYL & CLOUDFLARE REPAIR TOOL${NC}     ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"

# ==========================================
# PHASE 1: PANEL REPAIR (Fixing the 500 Error)
# ==========================================
echo -e "\n${BLUE}➤ PHASE 1: Repairing Panel Permissions & Cache${NC}"

if [ -d "/var/www/pterodactyl" ]; then
    cd /var/www/pterodactyl

    echo -e "${YELLOW}⏳ Resetting file ownership to www-data...${NC}"
    chown -R www-data:www-data /var/www/pterodactyl

    echo -e "${YELLOW}⏳ Setting directory permissions...${NC}"
    find /var/www/pterodactyl -type d -exec chmod 755 {} \;
    find /var/www/pterodactyl -type f -exec chmod 644 {} \;
    
    # Storage and Cache need write access
    chmod -R 775 /var/www/pterodactyl/storage
    chmod -R 775 /var/www/pterodactyl/bootstrap/cache

    echo -e "${YELLOW}⏳ Clearing Cache (as www-data user)...${NC}"
    # CRITICAL: Run as www-data so root doesn't own the cache files
    sudo -u www-data php artisan optimize:clear
    sudo -u www-data php artisan config:clear
    sudo -u www-data php artisan view:clear

    echo -e "${GREEN}✅ Panel permissions fixed. 500 Error should be gone.${NC}"
else
    echo -e "${RED}❌ Panel directory not found! Skipping Phase 1.${NC}"
fi

# ==========================================
# PHASE 2: WINGS CONFIGURATION (Fixing SSL Error)
# ==========================================
echo -e "\n${BLUE}➤ PHASE 2: Configuring Wings for Cloudflare Tunnel${NC}"

# Check if Wings is installed
if [ ! -f "/etc/pterodactyl/config.yml" ]; then
    echo -e "${YELLOW}⚠️  Wings config not found. Creating a new one.${NC}"
    mkdir -p /etc/pterodactyl
fi

# Stop wings temporarily
systemctl stop wings

echo -e "${CYAN}We need to set up the config manually to ensure SSL is OFF locally.${NC}"
echo -e "${WHITE}Please grab these details from your Admin Panel > Nodes > Configuration:${NC}"
echo ""

read -p "1. Enter Panel URL (e.g., https://main.verse-network.eu.org): " PANEL_URL
read -p "2. Enter Node UUID: " UUID
read -p "3. Enter Token ID: " TOKEN_ID
read -p "4. Enter Token Secret: " TOKEN_SECRET

# Strip trailing slash from URL
PANEL_URL=${PANEL_URL%/}

echo -e "${YELLOW}⏳ Writing Cloudflare-Optimized Config...${NC}"

# Create the config file
# KEY CHANGES: host is 0.0.0.0, ssl enabled is FALSE
cat > /etc/pterodactyl/config.yml <<EOF
debug: false
uuid: $UUID
token_id: $TOKEN_ID
token: $TOKEN_SECRET
system:
  log_directory: /var/log/pterodactyl
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: 2022
allowed_mounts: []
remote: '$PANEL_URL'
api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: false
    cert: /etc/certs/wing/fullchain.pem
    key: /etc/certs/wing/privkey.pem
  upload_limit: 100
EOF

echo -e "${GREEN}✅ Config written. Restarting Wings...${NC}"
systemctl restart wings

# Check if Wings started
sleep 2
if systemctl is-active --quiet wings; then
    echo -e "${GREEN}✅ Wings is RUNNING.${NC}"
else
    echo -e "${RED}❌ Wings failed to start. Run 'journalctl -u wings -n 20' to see why.${NC}"
fi

# ==========================================
# PHASE 3: FINAL INSTRUCTIONS
# ==========================================
echo -e "\n${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          ⚠️  FINAL REQUIRED CONFIGURATION  ⚠️             ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo -e "${WHITE}If you do not do these 2 steps, it will NOT work.${NC}"
echo ""

echo -e "${CYAN}STEP 1: Cloudflare Zero Trust (Access > Tunnels)${NC}"
echo -e "   Hostname: ${WHITE}wings.verse-network.eu.org${NC}"
echo -e "   Service:  ${GREEN}HTTP${NC}  (Crucial: NOT HTTPS)"
echo -e "   URL:      ${WHITE}localhost:8080${NC}"
echo ""

echo -e "${CYAN}STEP 2: Pterodactyl Admin (Nodes > Configuration)${NC}"
echo -e "   FQDN:               ${WHITE}wings.verse-network.eu.org${NC}"
echo -e "   Communicate via SSL:${GREEN} Use SSL Connection${NC} (Yes)"
echo -e "   Behind Proxy:       ${GREEN}Behind Proxy${NC}       (Yes)"
echo -e "   Daemon Port:        ${GREEN}443${NC}                  (Must be 443)"
echo -e "   SFTP Port:          ${WHITE}2022${NC}"
echo ""

echo -e "${YELLOW}Why?${NC} Browser (SSL) -> Cloudflare (SSL) -> Tunnel -> Wings (No SSL)"
echo -e "${GREEN}Configuration Complete.${NC}"

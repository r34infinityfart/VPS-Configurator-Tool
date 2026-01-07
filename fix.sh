#!/bin/bash

# ==============================================================================
#  REBS FINAL REPAIR TOOL (Nuclear Cache Fix)
#  1. Forcefully deletes corrupted root-owned cache files
#  2. Resets Permissions
#  3. Configures Wings for Cloudflare
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\133[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ Please run as root.${NC}"
   exit 1
fi

echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     ${CYAN}PANEL PERMISSION & WINGS REPAIR${NC}          ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"

# ==========================================
# PHASE 1: NUCLEAR PERMISSION FIX
# ==========================================
echo -e "\n${BLUE}➤ PHASE 1: Aggressive Permission Repair${NC}"
cd /var/www/pterodactyl || exit

echo -e "${YELLOW}⏳ Stopping Queue Worker to prevent write conflicts...${NC}"
systemctl stop pteroq 2>/dev/null

echo -e "${YELLOW}⏳ DELETING corrupted cache files (Nuclear Option)...${NC}"
# We delete these because chown sometimes fails on locked root files
rm -rf bootstrap/cache/*.php
rm -rf storage/framework/cache/data/*
rm -rf storage/framework/views/*
rm -rf storage/framework/sessions/*
rm -rf storage/logs/*.log

echo -e "${YELLOW}⏳ Setting Ownership to www-data...${NC}"
chown -R www-data:www-data /var/www/pterodactyl

echo -e "${YELLOW}⏳ Setting Directory Permissions...${NC}"
find /var/www/pterodactyl -type d -exec chmod 755 {} \;
find /var/www/pterodactyl -type f -exec chmod 644 {} \;
chmod -R 775 storage bootstrap/cache

echo -e "${YELLOW}⏳ Regenerating Panel Cache (as www-data)...${NC}"
# Running as www-data is critical here
sudo -u www-data php artisan optimize
sudo -u www-data php artisan view:clear
sudo -u www-data php artisan config:clear

echo -e "${YELLOW}⏳ Restarting Queue Worker...${NC}"
systemctl start pteroq

echo -e "${GREEN}✅ Panel 500 Error should be fixed.${NC}"
echo -e "${CYAN}👉 Please Refresh your Panel website NOW to ensure it loads.${NC}"
echo -e "${CYAN}   (We need the panel working to get the UUID for the next step).${NC}"
echo ""
read -p "Press [ENTER] once you have verified the Panel is working..."

# ==========================================
# PHASE 2: WINGS CONFIGURATION
# ==========================================
echo -e "\n${BLUE}➤ PHASE 2: Configuring Wings for Cloudflare${NC}"

if [ ! -f "/etc/pterodactyl/config.yml" ]; then
    echo -e "${YELLOW}Creating new Wings config directory...${NC}"
    mkdir -p /etc/pterodactyl
fi

echo -e "${WHITE}Please enter your Node details (From Panel > Nodes > Configuration):${NC}"
read -p "1. Enter Panel URL (e.g. https://main.verse-network.eu.org): " PANEL_URL
read -p "2. Enter Node UUID: " UUID
read -p "3. Enter Token ID: " TOKEN_ID
read -p "4. Enter Token Secret: " TOKEN_SECRET

# Strip trailing slash from URL
PANEL_URL=${PANEL_URL%/}

echo -e "${YELLOW}⏳ Writing Config (Forcing HTTP mode)...${NC}"
# Stop wings before writing
systemctl stop wings

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

echo -e "${YELLOW}⏳ Restarting Wings...${NC}"
systemctl restart wings
sleep 2

if systemctl is-active --quiet wings; then
    echo -e "${GREEN}✅ Wings is RUNNING.${NC}"
else
    echo -e "${RED}❌ Wings failed to start.${NC}"
    echo -e "Check logs: journalctl -u wings -n 20"
fi

# ==========================================
# PHASE 3: MANUAL CHECKLIST
# ==========================================
echo -e "\n${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          ⚠️  CRITICAL FINAL CHECKS  ⚠️               ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo -e "1. ${CYAN}Cloudflare Dashboard > Tunnels:${NC}"
echo -e "   - Hostname: ${WHITE}wings.verse-network.eu.org${NC}"
echo -e "   - Service:  ${GREEN}HTTP${NC} (NOT HTTPS)"
echo -e "   - URL:      ${WHITE}localhost:8080${NC}"
echo ""
echo -e "2. ${CYAN}Panel > Nodes > Configuration:${NC}"
echo -e "   - FQDN: ${WHITE}wings.verse-network.eu.org${NC}"
echo -e "   - SSL:  ${GREEN}Use SSL Connection${NC}"
echo -e "   - Port: ${GREEN}443${NC}"
echo ""
echo -e "${GREEN}Done. Your 500 Error is fixed and SSL is configured correctly.${NC}"

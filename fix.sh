#!/bin/bash

# REBS CF-WINGS REPAIR TOOL
# Fixes SSL Protocol Errors when using Cloudflare Tunnels

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\133[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   ${CYAN}CLOUDFLARE TUNNEL + WINGS REPAIR TOOL${NC}    ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo -e "${YELLOW}This tool will:${NC}"
echo -e " 1. Fix Panel Permissions (Solve 500 Error)"
echo -e " 2. Configure Wings for Tunneling (Disable local SSL)"
echo -e " 3. Tell you exactly what to put in Cloudflare"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ Please run as root.${NC}"
   exit 1
fi

# ==========================================
# STEP 1: FIX PANEL 500 ERROR
# ==========================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 1: Repairing Panel (Fixing 500 Errors)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ -d "/var/www/pterodactyl" ]; then
    echo -e "${YELLOW}⏳ Setting correct permissions...${NC}"
    chmod -R 755 /var/www/pterodactyl/storage bootstrap/cache 2>/dev/null
    chown -R www-data:www-data /var/www/pterodactyl/* 2>/dev/null
    
    echo -e "${YELLOW}⏳ Clearing Panel Cache...${NC}"
    cd /var/www/pterodactyl
    php artisan optimize:clear
    php artisan config:clear
    
    echo -e "${GREEN}✅ Panel permissions and cache reset.${NC}"
else
    echo -e "${RED}❌ Panel directory not found. Skipping Phase 1.${NC}"
fi

# ==========================================
# STEP 2: RECONFIGURE WINGS
# ==========================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 2: Configuring Wings for Cloudflare${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Stop wings to prevent errors during edit
systemctl stop wings

echo -e "${YELLOW}We need to rewrite your config.yml to force HTTP mode.${NC}"
echo -e "${YELLOW}Please copy these details from your Admin Panel -> Nodes -> Configuration tab:${NC}"
echo ""

read -p "1. Enter Panel URL (e.g. https://main.verse-network.eu.org): " PANEL_URL
read -p "2. Enter Node UUID: " UUID
read -p "3. Enter Token ID: " TOKEN_ID
read -p "4. Enter Token Secret: " TOKEN_SECRET

# Strip trailing slash from URL
PANEL_URL=${PANEL_URL%/}

echo -e "${YELLOW}⏳ Backing up old config...${NC}"
cp /etc/pterodactyl/config.yml /etc/pterodactyl/config.yml.bak 2>/dev/null

echo -e "${YELLOW}⏳ Writing new Cloudflare-Compatible Config...${NC}"

# This config forces SSL FALSE and binds to 0.0.0.0 so the Tunnel can find it
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

echo -e "${GREEN}✅ Config rewritten. Restarting Wings...${NC}"
systemctl restart wings

# Check status
if systemctl is-active --quiet wings; then
    echo -e "${GREEN}✅ Wings is RUNNING.${NC}"
else
    echo -e "${RED}❌ Wings failed to start. Check 'journalctl -u wings -n 50'${NC}"
fi

# ==========================================
# STEP 3: INSTRUCTIONS
# ==========================================
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              ⚠️  FINAL MANUAL STEPS REQUIRED  ⚠️             ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "You must configure the Cloudflare Dashboard and Pterodactyl Panel"
echo -e "EXACTLY like this, or the SSL Error will return."
echo ""

echo -e "${CYAN}1. CLOUDFLARE ZERO TRUST DASHBOARD (Access > Tunnels):${NC}"
echo -e "   ---------------------------------------------------------"
echo -e "   Hostname: ${WHITE}wings.verse-network.eu.org${NC}"
echo -e "   Service:  ${GREEN}HTTP${NC}  (NOT HTTPS!)"
echo -e "   URL:      ${WHITE}localhost:8080${NC}"
echo -e "   ${YELLOW}*Do NOT enable 'No TLS Verify', just use HTTP service type*${NC}"
echo ""

echo -e "${CYAN}2. PTERODACTYL ADMIN PANEL (Nodes > Configuration):${NC}"
echo -e "   ---------------------------------------------------------"
echo -e "   FQDN:               ${WHITE}wings.verse-network.eu.org${NC}"
echo -e "   Communicate via SSL:${GREEN} Use SSL Connection${NC} (Yes)"
echo -e "   Behind Proxy:       ${GREEN}Behind Proxy${NC}       (Yes)"
echo -e "   Daemon Port:        ${GREEN}443${NC}                  (Important!)"
echo -e "   SFTP Port:          ${WHITE}2022${NC}"
echo ""

echo -e "${YELLOW}Why these settings?${NC}"
echo -e "Because Cloudflare handles the SSL (Port 443). The tunnel sends"
echo -e "unencrypted traffic to Wings (Port 8080). If you turn SSL on in"
echo -e "Wings, Cloudflare gets confused and gives Protocol Error."
echo ""

#!/usr/bin/env bash
# ==========================================
# Cloudflare Tunnel + Zero Trust SSH Setup
# Ubuntu 24.04
# ==========================================
set -e

echo "=========================================="
echo " Cloudflare Tunnel + Zero Trust SSH"
echo "=========================================="

# ------------------------------------------
# 1. INSTALL CLOUDFLARED
# ------------------------------------------
echo ""
echo "[1/4] Installing cloudflared ..."

curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | \
    sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg

echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/cloudflared.list > /dev/null

sudo apt update
sudo apt install -y cloudflared

echo "cloudflared version:"
cloudflared --version

# ------------------------------------------
# 2. LOGIN TO CLOUDFLARE
# ------------------------------------------
echo ""
echo "[2/4] Cloudflare Login ..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Browser จะเปิด (หรือ copy URL) เพื่อ login"
echo " Cloudflare Zero Trust account ของคุณ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
cloudflared tunnel login

# ------------------------------------------
# 3. CREATE TUNNEL
# ------------------------------------------
echo ""
echo "[3/4] Creating Tunnel ..."
echo ""
read -rp "Enter tunnel name (e.g. my-server): " TUNNEL_NAME

cloudflared tunnel create "$TUNNEL_NAME"

# Get tunnel ID
TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
echo ""
echo "Tunnel ID: $TUNNEL_ID"

# Ask for SSH hostname
echo ""
read -rp "Enter your domain for SSH (e.g. ssh.example.com): " SSH_HOSTNAME

# Write config
sudo mkdir -p /etc/cloudflared
CRED_FILE="$HOME/.cloudflared/${TUNNEL_ID}.json"

sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${SSH_HOSTNAME}
    service: ssh://localhost:22
  - service: http_status:404
EOF

echo "Config: /etc/cloudflared/config.yml"

# Create DNS CNAME
cloudflared tunnel route dns "$TUNNEL_NAME" "$SSH_HOSTNAME"
echo "DNS CNAME: $SSH_HOSTNAME → $TUNNEL_ID.cfargotunnel.com"

# ------------------------------------------
# 4. ENABLE AS SYSTEMD SERVICE
# ------------------------------------------
echo ""
echo "[4/4] Enabling cloudflared service ..."

sudo cloudflared service install
sudo systemctl enable cloudflared
sudo systemctl start cloudflared

echo ""
echo "Cloudflared status:"
sudo systemctl status cloudflared --no-pager || true

# ------------------------------------------
# DONE
# ------------------------------------------
echo ""
echo "=========================================="
echo " CLOUDFLARE TUNNEL SETUP COMPLETE"
echo "=========================================="
echo ""
echo "TUNNEL INFO:"
echo "  Name : $TUNNEL_NAME"
echo "  ID   : $TUNNEL_ID"
echo "  Host : $SSH_HOSTNAME"
echo ""
echo "NEXT STEPS (Cloudflare Dashboard):"
echo "  1. https://one.dash.cloudflare.com"
echo "  2. Access → Applications → Add App → Self-hosted"
echo "  3. Domain: $SSH_HOSTNAME"
echo "  4. Add Policy → กำหนด email ที่อนุญาต"
echo ""
echo "SSH FROM CLIENT:"
echo "  เพิ่มใน ~/.ssh/config:"
echo ""
echo "    Host $SSH_HOSTNAME"
echo "      ProxyCommand cloudflared access ssh --hostname %h"
echo ""
echo "  แล้วรัน:"
echo "    ssh user@$SSH_HOSTNAME"
echo ""

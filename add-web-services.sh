#!/usr/bin/env bash
# ==========================================
# Cloudflare Tunnel — Add Web Services
# รันหลัง setup-cloudflare.sh เสร็จแล้ว
# Services: Portainer, Uptime Kuma, Dozzle
# ==========================================
set -e

echo "=========================================="
echo " Cloudflare Tunnel — Add Web Services"
echo "=========================================="

# ------------------------------------------
# ตรวจสอบ cloudflared และ tunnel ที่มีอยู่
# ------------------------------------------
if ! command -v cloudflared &>/dev/null; then
    echo "[ERROR] ไม่พบ cloudflared — รัน setup-cloudflare.sh ก่อน"
    exit 1
fi

if [ ! -f /etc/cloudflared/config.yml ]; then
    echo "[ERROR] ไม่พบ /etc/cloudflared/config.yml — รัน setup-cloudflare.sh ก่อน"
    exit 1
fi

# ดึง Tunnel ID และ credentials จาก config เดิม
TUNNEL_ID=$(grep "^tunnel:" /etc/cloudflared/config.yml | awk '{print $2}')
CRED_FILE=$(grep "^credentials-file:" /etc/cloudflared/config.yml | awk '{print $2}')
TUNNEL_NAME=$(cloudflared tunnel list | grep "$TUNNEL_ID" | awk '{print $2}')

echo ""
echo "Tunnel ที่ใช้อยู่:"
echo "  Name : $TUNNEL_NAME"
echo "  ID   : $TUNNEL_ID"
echo ""

# ------------------------------------------
# ถามชื่อ domain หลัก
# ------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ใส่ domain หลักที่จัดการใน Cloudflare"
echo " เช่น example.com"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -rp "Base domain: " BASE_DOMAIN

# กำหนด subdomain อัตโนมัติ
PORTAINER_HOST="portainer.${BASE_DOMAIN}"
KUMA_HOST="status.${BASE_DOMAIN}"
DOZZLE_HOST="logs.${BASE_DOMAIN}"

echo ""
echo "Subdomains ที่จะสร้าง:"
echo "  $PORTAINER_HOST  →  Portainer   (port 9000)"
echo "  $KUMA_HOST       →  Uptime Kuma (port 3001)"
echo "  $DOZZLE_HOST     →  Dozzle      (port 8080)"
echo ""
read -rp "ยืนยัน? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "ยกเลิก"
    exit 0
fi

# ------------------------------------------
# อ่าน ingress เดิม (SSH ที่ตั้งไว้แล้ว)
# ------------------------------------------
# ดึงบรรทัด SSH ingress เดิมออกมาเก็บไว้
SSH_INGRESS=$(grep -A2 "service: ssh" /etc/cloudflared/config.yml | head -4 || echo "")
SSH_HOST=$(grep -B1 "service: ssh" /etc/cloudflared/config.yml | grep "hostname:" | awk '{print $2}' || echo "")

# ------------------------------------------
# เขียน config.yml ใหม่ (รวม SSH เดิม + services ใหม่)
# ------------------------------------------
echo ""
echo "[1/2] อัปเดต /etc/cloudflared/config.yml ..."

# สร้าง config ทั้งหมดในตัวแปรก่อน แล้วเขียนครั้งเดียว
CONFIG="tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}

ingress:"

# เพิ่ม SSH เดิม (ถ้ามี)
if [ -n "$SSH_HOST" ]; then
    CONFIG="${CONFIG}
  - hostname: ${SSH_HOST}
    service: ssh://localhost:22
"
fi

# เพิ่ม web services ใหม่
CONFIG="${CONFIG}
  - hostname: ${PORTAINER_HOST}
    service: http://portainer:9000

  - hostname: ${KUMA_HOST}
    service: http://uptime-kuma:3001

  - hostname: ${DOZZLE_HOST}
    service: http://dozzle:8080

  - service: http_status:404"

echo "$CONFIG" | sudo tee /etc/cloudflared/config.yml > /dev/null

echo "Config อัปเดตแล้ว:"
cat /etc/cloudflared/config.yml

# ------------------------------------------
# สร้าง DNS CNAME สำหรับแต่ละ service
# ------------------------------------------
echo ""
echo "[2/2] สร้าง DNS CNAME records ..."

cloudflared tunnel route dns "$TUNNEL_NAME" "$PORTAINER_HOST"
echo "  $PORTAINER_HOST → $TUNNEL_ID.cfargotunnel.com"

cloudflared tunnel route dns "$TUNNEL_NAME" "$KUMA_HOST"
echo "  $KUMA_HOST → $TUNNEL_ID.cfargotunnel.com"

cloudflared tunnel route dns "$TUNNEL_NAME" "$DOZZLE_HOST"
echo "  $DOZZLE_HOST → $TUNNEL_ID.cfargotunnel.com"

# ------------------------------------------
# Restart cloudflared เพื่อ reload config
# ------------------------------------------
echo ""
echo "Restarting cloudflared ..."
sudo systemctl restart cloudflared
sleep 2
sudo systemctl status cloudflared --no-pager || true

# ------------------------------------------
# DONE
# ------------------------------------------
echo ""
echo "=========================================="
echo " WEB SERVICES SETUP COMPLETE"
echo "=========================================="
echo ""
echo "URLs:"
echo "  https://$PORTAINER_HOST   → Portainer"
echo "  https://$KUMA_HOST        → Uptime Kuma"
echo "  https://$DOZZLE_HOST      → Dozzle"
echo ""
echo "NEXT STEPS — ตั้ง Access Policy (สำคัญ!):"
echo "  1. https://one.dash.cloudflare.com"
echo "  2. Access → Applications → Add App → Self-hosted"
echo "  3. ทำซ้ำสำหรับแต่ละ subdomain:"
echo "     - $PORTAINER_HOST"
echo "     - $KUMA_HOST"
echo "     - $DOZZLE_HOST"
echo "  4. Add Policy → กำหนด email ที่อนุญาต"
echo ""
echo "หาก Docker container ยังไม่ได้รัน:"
echo "  docker compose up -d"
echo ""

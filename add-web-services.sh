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
# ตรวจสอบ prerequisites
# ------------------------------------------
if ! command -v cloudflared &>/dev/null; then
    echo "[ERROR] ไม่พบ cloudflared — รัน setup-cloudflare.sh ก่อน"
    exit 1
fi

if [ ! -f /etc/cloudflared/config.yml ]; then
    echo "[ERROR] ไม่พบ /etc/cloudflared/config.yml — รัน setup-cloudflare.sh ก่อน"
    exit 1
fi

# ------------------------------------------
# ดึงข้อมูล tunnel จาก config เดิม
# FIX: ใช้ cut -d' ' -f2- แทน awk '{print $2}'
#      เพื่อรองรับ path ที่มี : และ / ได้ครบ
# ------------------------------------------
TUNNEL_ID=$(grep "^tunnel:" /etc/cloudflared/config.yml | awk '{print $2}' | tr -d '[:space:]')
CRED_FILE=$(grep "^credentials-file:" /etc/cloudflared/config.yml | cut -d' ' -f2- | tr -d '[:space:]')
TUNNEL_NAME=$(cloudflared tunnel list | grep "$TUNNEL_ID" | awk '{print $2}')

# FIX: ใช้ awk '{print $NF}' แทน awk '{print $2}' สำหรับ hostname
SSH_HOST=$(grep -B1 "service: ssh://localhost" /etc/cloudflared/config.yml \
    | grep "hostname:" | sed 's/.*hostname:[[:space:]]*//' | tr -d '[:space:]' || true)
if [ "$SSH_HOST" = "hostname:" ]; then
    SSH_HOST=""
fi

echo ""
echo "Tunnel ที่ใช้อยู่:"
echo "  Name : $TUNNEL_NAME"
echo "  ID   : $TUNNEL_ID"
echo "  Creds: $CRED_FILE"
[ -n "$SSH_HOST" ] && echo "  SSH  : $SSH_HOST (จะเก็บไว้)"
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

PORTAINER_HOST="portainer.${BASE_DOMAIN}"
KUMA_HOST="status.${BASE_DOMAIN}"
DOZZLE_HOST="logs.${BASE_DOMAIN}"

echo ""
echo "Subdomains ที่จะสร้าง:"
echo "  $PORTAINER_HOST  →  Portainer   (port 9000)"
echo "  $KUMA_HOST  →  Uptime Kuma (port 3001)"
echo "  $DOZZLE_HOST  →  Dozzle      (port 8080)"
echo ""
read -rp "ยืนยัน? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "ยกเลิก"
    exit 0
fi

# ------------------------------------------
# เขียน config.yml ด้วย printf
# ------------------------------------------
echo ""
echo "[1/2] อัปเดต /etc/cloudflared/config.yml ..."

TMPFILE=$(mktemp)

printf 'tunnel: %s\n' "$TUNNEL_ID"            >> "$TMPFILE"
printf 'credentials-file: %s\n' "$CRED_FILE"  >> "$TMPFILE"
printf '\n'                                    >> "$TMPFILE"
printf 'ingress:\n'                            >> "$TMPFILE"

if [ -n "$SSH_HOST" ]; then
    printf '  - hostname: %s\n' "$SSH_HOST"    >> "$TMPFILE"
    printf '    service: ssh://localhost:22\n' >> "$TMPFILE"
    printf '\n'                                >> "$TMPFILE"
fi

printf '  - hostname: %s\n' "$PORTAINER_HOST"  >> "$TMPFILE"
printf '    service: http://portainer:9000\n'  >> "$TMPFILE"
printf '\n'                                    >> "$TMPFILE"

printf '  - hostname: %s\n' "$KUMA_HOST"       >> "$TMPFILE"
printf '    service: http://uptime-kuma:3001\n' >> "$TMPFILE"
printf '\n'                                    >> "$TMPFILE"

printf '  - hostname: %s\n' "$DOZZLE_HOST"     >> "$TMPFILE"
printf '    service: http://dozzle:8080\n'     >> "$TMPFILE"
printf '\n'                                    >> "$TMPFILE"

printf '  - service: http_status:404\n'        >> "$TMPFILE"

echo ""
echo "--- Config ที่จะเขียน ---"
cat "$TMPFILE"
echo "-------------------------"
echo ""

sudo cp "$TMPFILE" /etc/cloudflared/config.yml
rm -f "$TMPFILE"
echo "เขียน config สำเร็จ ✓"

# ------------------------------------------
# สร้าง DNS CNAME
# ------------------------------------------
echo ""
echo "[2/2] สร้าง DNS CNAME records ..."

cloudflared tunnel route dns "$TUNNEL_NAME" "$PORTAINER_HOST"
echo "  $PORTAINER_HOST ✓"

cloudflared tunnel route dns "$TUNNEL_NAME" "$KUMA_HOST"
echo "  $KUMA_HOST ✓"

cloudflared tunnel route dns "$TUNNEL_NAME" "$DOZZLE_HOST"
echo "  $DOZZLE_HOST ✓"

# ------------------------------------------
# Restart cloudflared
# ------------------------------------------
echo ""
echo "Restarting cloudflared ..."
sudo systemctl restart cloudflared
sleep 2
sudo systemctl status cloudflared --no-pager || true

echo ""
echo "=========================================="
echo " WEB SERVICES SETUP COMPLETE"
echo "=========================================="
echo ""
echo "URLs:"
echo "  https://$PORTAINER_HOST  →  Portainer"
echo "  https://$KUMA_HOST  →  Uptime Kuma"
echo "  https://$DOZZLE_HOST  →  Dozzle"
echo ""
echo "NEXT STEPS — ตั้ง Access Policy (สำคัญ!):"
echo "  1. https://one.dash.cloudflare.com"
echo "  2. Access → Applications → Add App → Self-hosted"
echo "  3. ทำซ้ำสำหรับแต่ละ subdomain"
echo "  4. Add Policy → กำหนด email ที่อนุญาต"
echo ""

#!/usr/bin/env bash
# ==========================================
# Cloudflare Tunnel — Add Single Service
# ใช้เพิ่ม service ใหม่ทีละตัว
# ==========================================
set -e

echo "=========================================="
echo " Add New Service to Cloudflare Tunnel"
echo "=========================================="

# ------------------------------------------
# ตรวจสอบ prerequisites
# ------------------------------------------
if ! command -v cloudflared &>/dev/null; then
    echo "[ERROR] ไม่พบ cloudflared"
    exit 1
fi

if [ ! -f /etc/cloudflared/config.yml ]; then
    echo "[ERROR] ไม่พบ /etc/cloudflared/config.yml"
    exit 1
fi

# ------------------------------------------
# ดึงข้อมูล tunnel
# ------------------------------------------
TUNNEL_ID=$(grep "^tunnel:" /etc/cloudflared/config.yml | awk '{print $2}' | tr -d '[:space:]')
CRED_FILE=$(grep "^credentials-file:" /etc/cloudflared/config.yml | awk '{print $2}' | tr -d '[:space:]')
TUNNEL_NAME=$(cloudflared tunnel list | grep "$TUNNEL_ID" | awk '{print $2}')

echo ""
echo "Tunnel: $TUNNEL_NAME ($TUNNEL_ID)"
echo ""

# ------------------------------------------
# แสดง ingress ที่มีอยู่แล้ว
# ------------------------------------------
echo "Services ที่มีอยู่แล้ว:"
grep "hostname:" /etc/cloudflared/config.yml | awk '{print "  -", $2}'
echo ""

# ------------------------------------------
# ถามข้อมูล service ใหม่
# ------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -rp "Hostname (เช่น myapp.example.com): " NEW_HOST
read -rp "Container name หรือ IP (เช่น myapp): " CONTAINER
read -rp "Port ของ container (เช่น 3000): " PORT
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SERVICE_URL="http://${CONTAINER}:${PORT}"

echo ""
echo "จะเพิ่ม:"
echo "  $NEW_HOST  →  $SERVICE_URL"
echo ""
read -rp "ยืนยัน? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "ยกเลิก"
    exit 0
fi

# ------------------------------------------
# อ่าน ingress เดิมทั้งหมด (ยกเว้น catch-all)
# แล้วเพิ่ม service ใหม่ก่อน http_status:404
# ------------------------------------------
echo ""
echo "[1/2] อัปเดต config.yml ..."

TMPFILE=$(mktemp)

# เขียน header
printf 'tunnel: %s\n' "$TUNNEL_ID"          >> "$TMPFILE"
printf 'credentials-file: %s\n' "$CRED_FILE" >> "$TMPFILE"
printf '\n'                                   >> "$TMPFILE"
printf 'ingress:\n'                           >> "$TMPFILE"

# คัดลอก ingress เดิมทั้งหมด (ยกเว้น catch-all บรรทัดสุดท้าย)
in_ingress=false
while IFS= read -r line; do
    # ข้ามหลังเจอ ingress: แล้ว
    if [[ "$line" =~ ^ingress: ]]; then
        in_ingress=true
        continue
    fi
    # ข้าม catch-all
    if [[ "$line" =~ "service: http_status:404" ]]; then
        continue
    fi
    if $in_ingress; then
        printf '%s\n' "$line" >> "$TMPFILE"
    fi
done < /etc/cloudflared/config.yml

# เพิ่ม service ใหม่
printf '  - hostname: %s\n' "$NEW_HOST"      >> "$TMPFILE"
printf '    service: %s\n' "$SERVICE_URL"     >> "$TMPFILE"
printf '\n'                                   >> "$TMPFILE"

# เพิ่ม catch-all กลับ
printf '  - service: http_status:404\n'       >> "$TMPFILE"

echo ""
echo "--- Config ใหม่ ---"
cat "$TMPFILE"
echo "-------------------"
echo ""

sudo cp "$TMPFILE" /etc/cloudflared/config.yml
rm -f "$TMPFILE"
echo "เขียน config สำเร็จ ✓"

# ------------------------------------------
# สร้าง DNS CNAME
# ------------------------------------------
echo ""
echo "[2/2] สร้าง DNS CNAME ..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$NEW_HOST"
echo "  $NEW_HOST → $TUNNEL_ID.cfargotunnel.com ✓"

# ------------------------------------------
# Restart
# ------------------------------------------
echo ""
echo "Restarting cloudflared ..."
sudo systemctl restart cloudflared
sleep 2
sudo systemctl status cloudflared --no-pager || true

echo ""
echo "=========================================="
echo " DONE"
echo "=========================================="
echo ""
echo "  https://$NEW_HOST  →  $SERVICE_URL"
echo ""
echo "อย่าลืมตั้ง Access Policy ถ้าต้องการ:"
echo "  https://one.dash.cloudflare.com"
echo "  Access → Applications → Add App → Self-hosted"
echo ""

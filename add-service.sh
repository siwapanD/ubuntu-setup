#!/usr/bin/env bash
# ==========================================
# Cloudflare Tunnel — Add Single Service
# ใช้ Cloudflare API (รองรับ Remote config)
# ==========================================
set -e

echo "=========================================="
echo " Add New Service to Cloudflare Tunnel"
echo "=========================================="

# ------------------------------------------
# ตรวจสอบ dependencies
# ------------------------------------------
if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "[ERROR] ต้องการ curl และ jq"
    exit 1
fi

# ------------------------------------------
# ดึง Tunnel ID จาก config เดิม
# ------------------------------------------
if [ ! -f /etc/cloudflared/config.yml ]; then
    echo "[ERROR] ไม่พบ /etc/cloudflared/config.yml"
    exit 1
fi

TUNNEL_ID=$(sudo awk '$1 == "tunnel:" {print $2; exit}' /etc/cloudflared/config.yml | tr -d '[:space:]')
if ! [[ "$TUNNEL_ID" =~ ^[a-fA-F0-9-]{36}$ ]]; then
    echo "[ERROR] อ่าน Tunnel ID ไม่ได้จาก /etc/cloudflared/config.yml"
    echo "        ตรวจสอบไฟล์และสิทธิ์ sudo แล้วลองใหม่"
    exit 1
fi
echo ""
echo "Tunnel ID: $TUNNEL_ID"
echo ""

# ------------------------------------------
# โหลด Cloudflare credentials (auto จาก cloudflare.env)
# ------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/cf-credentials.sh"
load_cf_credentials

# ------------------------------------------
# ถามข้อมูล service ใหม่
# ------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Service ที่จะเพิ่ม"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -rp "Hostname (เช่น myapp.beeempire.studio): " NEW_HOST
read -rp "Container port (เช่น 3000): " PORT
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "[ERROR] Port ต้องเป็นตัวเลขระหว่าง 1-65535"
    exit 1
fi
read -rp "Protocol [1=HTTP, 2=TCP] (default 1): " PROTOCOL_CHOICE
case "${PROTOCOL_CHOICE:-1}" in
    1) SERVICE_URL="http://localhost:${PORT}" ;;
    2) SERVICE_URL="tcp://localhost:${PORT}" ;;
    *) echo "[ERROR] เลือก protocol ไม่ถูกต้อง"; exit 1 ;;
esac

echo ""
echo "จะเพิ่ม:  $NEW_HOST  →  $SERVICE_URL"
echo ""
read -rp "ยืนยัน? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "ยกเลิก"
    exit 0
fi

# ------------------------------------------
# ดึง ingress rules ปัจจุบันจาก API
# ------------------------------------------
echo ""
echo "[1/3] ดึง config ปัจจุบันจาก Cloudflare ..."

CURRENT=$(curl -s \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations")

if ! echo "$CURRENT" | jq -e '.success' | grep -q true; then
    echo "[ERROR] API call ล้มเหลว:"
    echo "$CURRENT" | jq '.errors'
    exit 1
fi

# ดึง ingress rules เดิม (ยกเว้น catch-all)
EXISTING_RULES=$(echo "$CURRENT" | jq '[.result.config.ingress[] | select(.service != "http_status:404")]')
echo "Rules ปัจจุบัน:"
echo "$EXISTING_RULES" | jq -r '.[] | "  - \(.hostname) → \(.service)"'

# ------------------------------------------
# สร้าง ingress rules ใหม่
# ------------------------------------------
NEW_RULE=$(jq -n \
    --arg hostname "$NEW_HOST" \
    --arg service "$SERVICE_URL" \
    '{"hostname": $hostname, "service": $service, "originRequest": {}}')

# รวม rules เดิม + ใหม่ + catch-all
NEW_INGRESS=$(echo "$EXISTING_RULES" | jq \
    --argjson new_rule "$NEW_RULE" \
    '. + [$new_rule] + [{"service": "http_status:404"}]')

# ------------------------------------------
# Push config ใหม่ขึ้น Cloudflare
# ------------------------------------------
echo ""
echo "[2/3] อัปเดต config ขึ้น Cloudflare ..."

PAYLOAD=$(jq -n --argjson ingress "$NEW_INGRESS" '{"config": {"ingress": $ingress}}')

RESULT=$(curl -s -X PUT \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations")

if echo "$RESULT" | jq -e '.success' | grep -q true; then
    echo "อัปเดต config สำเร็จ ✓"
else
    echo "[ERROR] อัปเดตล้มเหลว:"
    echo "$RESULT" | jq '.errors'
    exit 1
fi

# ------------------------------------------
# สร้าง DNS CNAME
# ------------------------------------------
echo ""
echo "[3/3] สร้าง DNS CNAME ..."
cloudflared tunnel route dns "$TUNNEL_ID" "$NEW_HOST" && \
    echo "  $NEW_HOST ✓" || \
    echo "  [WARN] DNS อาจมีอยู่แล้ว ตรวจสอบใน Cloudflare Dashboard"

# ------------------------------------------
# DONE
# ------------------------------------------
echo ""
echo "=========================================="
echo " DONE"
echo "=========================================="
echo ""
echo "  $NEW_HOST  →  $SERVICE_URL"
if [[ "$SERVICE_URL" == tcp://* ]]; then
    echo "  Client: cloudflared access tcp --hostname $NEW_HOST --url localhost:$PORT"
    echo "  ตั้ง PostgreSQL/แอป client ให้เชื่อม localhost:$PORT และกำหนด Access Application/Policy ใน Cloudflare ก่อนใช้งาน"
fi
echo ""
echo "Routes ทั้งหมดตอนนี้:"
echo "$NEW_INGRESS" | jq -r '.[] | select(.hostname) | "  - \(.hostname) → \(.service)"'
echo ""
echo "อย่าลืมตั้ง Access Policy ถ้าต้องการ:"
echo "  https://one.dash.cloudflare.com"
echo "  Access → Applications → Add App → Self-hosted"
echo ""
#!/usr/bin/env bash
# ==========================================
# Cloudflare Tunnel — Add Web Services
# ใช้ Cloudflare API (รองรับ Remote config)
# Services: Portainer, Uptime Kuma, Dozzle
# ==========================================
set -e

echo "=========================================="
echo " Cloudflare Tunnel — Add Web Services"
echo "=========================================="

# ------------------------------------------
# ตรวจสอบ dependencies
# ------------------------------------------
if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "[ERROR] ต้องการ curl และ jq"
    exit 1
fi

if ! command -v cloudflared &>/dev/null; then
    echo "[ERROR] ไม่พบ cloudflared — รัน setup-cloudflare.sh ก่อน"
    exit 1
fi

if [ ! -f /etc/cloudflared/config.yml ]; then
    echo "[ERROR] ไม่พบ /etc/cloudflared/config.yml"
    exit 1
fi

# ------------------------------------------
# ดึง Tunnel ID จาก config
# ------------------------------------------
TUNNEL_ID=$(grep "^tunnel:" /etc/cloudflared/config.yml | awk '{print $2}' | tr -d '[:space:]')
TUNNEL_NAME=$(cloudflared tunnel list | grep "$TUNNEL_ID" | awk '{print $2}')

echo ""
echo "Tunnel: $TUNNEL_NAME ($TUNNEL_ID)"
echo ""

# ------------------------------------------
# ขอ Cloudflare credentials
# ------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Cloudflare API Credentials"
echo " ดูได้ที่: https://dash.cloudflare.com/profile/api-tokens"
echo " Permissions ที่ต้องการ:"
echo "   - Cloudflare Tunnel: Edit"
echo "   - DNS: Edit"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -rp "Cloudflare Account ID : " CF_ACCOUNT_ID
read -rsp "Cloudflare API Token  : " CF_API_TOKEN
echo ""

# ------------------------------------------
# ถาม base domain
# ------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -rp "Base domain (เช่น beeempire.studio): " BASE_DOMAIN

PORTAINER_HOST="portainer.${BASE_DOMAIN}"
KUMA_HOST="status.${BASE_DOMAIN}"
DOZZLE_HOST="logs.${BASE_DOMAIN}"

echo ""
echo "Subdomains ที่จะสร้าง:"
echo "  $PORTAINER_HOST  →  http://localhost:9000"
echo "  $KUMA_HOST       →  http://localhost:3001"
echo "  $DOZZLE_HOST     →  http://localhost:8080"
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

# ดึง ingress เดิม ยกเว้น catch-all และ services ที่จะเพิ่มใหม่ (ป้องกัน duplicate)
EXISTING_RULES=$(echo "$CURRENT" | jq --arg p "$PORTAINER_HOST" --arg k "$KUMA_HOST" --arg d "$DOZZLE_HOST" '
    [.result.config.ingress[]
    | select(.service != "http_status:404")
    | select(.hostname != $p)
    | select(.hostname != $k)
    | select(.hostname != $d)
    ]')

echo "Rules เดิมที่จะเก็บไว้:"
echo "$EXISTING_RULES" | jq -r '.[] | "  - \(.hostname) → \(.service)"'

# ------------------------------------------
# สร้าง ingress rules ใหม่
# ------------------------------------------
NEW_RULES=$(jq -n \
    --arg p_host "$PORTAINER_HOST" \
    --arg k_host "$KUMA_HOST" \
    --arg d_host "$DOZZLE_HOST" \
    '[
        {"hostname": $p_host, "service": "http://localhost:9000", "originRequest": {}},
        {"hostname": $k_host, "service": "http://localhost:3001", "originRequest": {}},
        {"hostname": $d_host, "service": "http://localhost:8080", "originRequest": {}},
        {"service": "http_status:404"}
    ]')

# รวม rules เดิม + ใหม่
FINAL_INGRESS=$(echo "$EXISTING_RULES" | jq --argjson new "$NEW_RULES" '. + $new')

# ------------------------------------------
# Push config ใหม่ขึ้น Cloudflare
# ------------------------------------------
echo ""
echo "[2/3] อัปเดต config ขึ้น Cloudflare ..."

PAYLOAD=$(jq -n --argjson ingress "$FINAL_INGRESS" '{"config": {"ingress": $ingress}}')

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
# สร้าง DNS CNAME ทั้ง 3
# ------------------------------------------
echo ""
echo "[3/3] สร้าง DNS CNAME records ..."

for HOST in "$PORTAINER_HOST" "$KUMA_HOST" "$DOZZLE_HOST"; do
    cloudflared tunnel route dns "$TUNNEL_ID" "$HOST" && \
        echo "  $HOST ✓" || \
        echo "  [WARN] $HOST DNS อาจมีอยู่แล้ว"
done

# ------------------------------------------
# DONE
# ------------------------------------------
echo ""
echo "=========================================="
echo " WEB SERVICES SETUP COMPLETE"
echo "=========================================="
echo ""
echo "URLs:"
echo "  https://$PORTAINER_HOST  →  Portainer"
echo "  https://$KUMA_HOST       →  Uptime Kuma"
echo "  https://$DOZZLE_HOST     →  Dozzle"
echo ""
echo "Routes ทั้งหมดตอนนี้:"
echo "$FINAL_INGRESS" | jq -r '.[] | select(.hostname) | "  - \(.hostname) → \(.service)"'
echo ""
echo "อย่าลืมตั้ง Access Policy:"
echo "  https://one.dash.cloudflare.com"
echo "  Access → Applications → Add App → Self-hosted"
echo ""

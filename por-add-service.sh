#!/usr/bin/env bash
# ==========================================
# Cloudflare Tunnel — Add Single Service
# ดึง container list จาก Portainer API
# ==========================================
set -e

echo "=========================================="
echo " Add New Service to Cloudflare Tunnel"
echo " (Auto-detect จาก Portainer)"
echo "=========================================="

# ------------------------------------------
# ตรวจสอบ dependencies
# ------------------------------------------
if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "[ERROR] ต้องการ curl และ jq"
    exit 1
fi

if [ ! -f /etc/cloudflared/config.yml ]; then
    echo "[ERROR] ไม่พบ /etc/cloudflared/config.yml"
    exit 1
fi

# ------------------------------------------
# โหลด Cloudflare credentials
# ------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/cf-credentials.sh"
load_cf_credentials

# ------------------------------------------
# ดึง Tunnel ID
# ------------------------------------------
TUNNEL_ID=$(grep "^tunnel:" /etc/cloudflared/config.yml | awk '{print $2}' | tr -d '[:space:]')
echo ""
echo "Tunnel ID: $TUNNEL_ID"

# ------------------------------------------
# Login Portainer และดึง container list
# ------------------------------------------
PORTAINER_URL="${PT_URL:-http://localhost:9000}"
echo ""
echo "Portainer: $PORTAINER_URL (user: $PT_USER)"

# Login เอา JWT token
PT_TOKEN=$(curl -s -X POST "$PORTAINER_URL/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$PT_USER\",\"password\":\"$PT_PASS\"}" \
    | jq -r '.jwt')

if [ -z "$PT_TOKEN" ] || [ "$PT_TOKEN" = "null" ]; then
    echo "[ERROR] Login Portainer ไม่สำเร็จ — ตรวจสอบ username/password"
    exit 1
fi
echo "Login Portainer สำเร็จ ✓"

# ดึง endpoint ID (environment แรก)
ENDPOINT_ID=$(curl -s -H "Authorization: Bearer $PT_TOKEN" \
    "$PORTAINER_URL/api/endpoints" | jq '.[0].Id')

# ดึง containers ที่รันอยู่ พร้อม port mappings
echo ""
echo "กำลังดึง container list..."

CONTAINERS=$(curl -s -H "Authorization: Bearer $PT_TOKEN" \
    "$PORTAINER_URL/api/endpoints/$ENDPOINT_ID/docker/containers/json?all=false" \
    | jq '[.[] | {
        name: (.Names[0] | ltrimstr("/")),
        ports: [.Ports[] | select(.PublicPort != null) | {public: .PublicPort, private: .PrivatePort}]
    } | select(.ports | length > 0)]')

# ตรวจสอบว่ามี container ที่ expose port
COUNT=$(echo "$CONTAINERS" | jq 'length')
if [ "$COUNT" -eq 0 ]; then
    echo "[ERROR] ไม่พบ container ที่มี port expose"
    echo "        ตรวจสอบว่า container มี ports mapping ใน docker-compose.yml"
    exit 1
fi

# ------------------------------------------
# แสดงรายการ container ให้เลือก
# ------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Containers ที่พร้อมใช้งาน"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# สร้าง array สำหรับเลือก
declare -a CONTAINER_NAMES
declare -a CONTAINER_PORTS
IDX=1

while IFS= read -r line; do
    NAME=$(echo "$line" | jq -r '.name')
    # เอา port แรกที่ expose
    PORT=$(echo "$line" | jq -r '.ports[0].public')
    PRIV=$(echo "$line" | jq -r '.ports[0].private')
    CONTAINER_NAMES+=("$NAME")
    CONTAINER_PORTS+=("$PORT")
    echo "  [$IDX] $NAME  (port: $PORT → $PRIV)"
    ((IDX++))
done < <(echo "$CONTAINERS" | jq -c '.[]')

echo ""
read -rp "เลือก container [1-$((IDX-1))]: " CHOICE

# validate
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt $((IDX-1)) ]; then
    echo "[ERROR] เลือกไม่ถูกต้อง"
    exit 1
fi

SEL_NAME="${CONTAINER_NAMES[$((CHOICE-1))]}"
SEL_PORT="${CONTAINER_PORTS[$((CHOICE-1))]}"

echo ""
echo "เลือก: $SEL_NAME (port $SEL_PORT)"

# ------------------------------------------
# ถาม subdomain
# ------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ดึง base domain จาก config ที่มีอยู่
EXISTING_HOST=$(curl -s \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
    | jq -r '.result.config.ingress[0].hostname // ""' | sed 's/.*\.\(.*\..*\)/\1/')

read -rp "Subdomain (จะใช้ .${EXISTING_HOST}): " SUBDOMAIN
NEW_HOST="${SUBDOMAIN}.${EXISTING_HOST}"
SERVICE_URL="http://localhost:${SEL_PORT}"

echo ""
echo "จะเพิ่ม:  https://$NEW_HOST  →  $SERVICE_URL  ($SEL_NAME)"
echo ""
read -rp "ยืนยัน? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "ยกเลิก"
    exit 0
fi

# ------------------------------------------
# ดึง ingress เดิม + เพิ่มใหม่
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

EXISTING_RULES=$(echo "$CURRENT" | jq --arg h "$NEW_HOST" \
    '[.result.config.ingress[] | select(.service != "http_status:404") | select(.hostname != $h)]')

NEW_RULE=$(jq -n \
    --arg hostname "$NEW_HOST" \
    --arg service "$SERVICE_URL" \
    '{"hostname": $hostname, "service": $service, "originRequest": {}}')

FINAL_INGRESS=$(echo "$EXISTING_RULES" | jq \
    --argjson new "$NEW_RULE" \
    '. + [$new] + [{"service": "http_status:404"}]')

# ------------------------------------------
# Push ขึ้น Cloudflare
# ------------------------------------------
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
# สร้าง DNS CNAME
# ------------------------------------------
echo "[3/3] สร้าง DNS CNAME ..."
cloudflared tunnel route dns "$TUNNEL_ID" "$NEW_HOST" && \
    echo "  $NEW_HOST ✓" || \
    echo "  [WARN] DNS อาจมีอยู่แล้ว"

# ------------------------------------------
# DONE
# ------------------------------------------
echo ""
echo "=========================================="
echo " DONE"
echo "=========================================="
echo ""
echo "  Container : $SEL_NAME"
echo "  Port      : $SEL_PORT"
echo "  URL       : https://$NEW_HOST"
echo ""
echo "Routes ทั้งหมดตอนนี้:"
echo "$FINAL_INGRESS" | jq -r '.[] | select(.hostname) | "  - \(.hostname) → \(.service)"'
echo ""
echo "อย่าลืมตั้ง Access Policy ถ้าต้องการ:"
echo "  https://one.dash.cloudflare.com"
echo "  Access → Applications → Add App → Self-hosted"
echo ""
#!/usr/bin/env bash
# ==========================================
# Cloudflare Tunnel — SSH + Web Setup
# Ubuntu 24.04
# ==========================================
set -Eeuo pipefail

API="https://api.cloudflare.com/client/v4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/cloudflare.env"

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

api_get() {
    curl -fsS --connect-timeout 10 --max-time 30 \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" "$1"
}

api_success() {
    jq -e '.success == true' >/dev/null 2>&1 <<< "$1"
}

ensure_dns_route() {
    local host="$1" target="$2" records record_id record_content record_proxied payload result
    records=$(api_get "$API/zones/$ZONE_ID/dns_records?name=$host&per_page=100") || return 1
    api_success "$records" || { jq '.errors' <<< "$records" >&2; return 1; }
    local count
    count=$(jq --arg host "$host" '[.result[] | select((.name | ascii_downcase) == $host)] | length' <<< "$records")

    if [[ "$count" -eq 0 ]]; then
        payload=$(jq -n --arg name "$host" --arg content "$target" \
            '{type:"CNAME", name:$name, content:$content, ttl:1, proxied:true}')
        result=$(curl -fsS --connect-timeout 10 --max-time 30 -X POST \
            -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
            -d "$payload" "$API/zones/$ZONE_ID/dns_records") || return 1
    elif [[ "$count" -eq 1 ]] && [[ "$(jq -r '.result[0].type' <<< "$records")" == "CNAME" ]]; then
        record_id=$(jq -r '.result[0].id' <<< "$records")
        record_type=$(jq -r '.result[0].type' <<< "$records")
        record_content=$(jq -r '.result[0].content' <<< "$records")
        record_proxied=$(jq -r '.result[0].proxied' <<< "$records")
        # Keep the record only if it targets this Tunnel and is proxied by Cloudflare.
        if [[ "${record_content,,}" == "${target,,}" && "$record_proxied" == "true" ]]; then
            return 0
        fi
        payload=$(jq -n --arg name "$host" --arg content "$target" \
            '{type:"CNAME", name:$name, content:$content, ttl:1, proxied:true}')
        result=$(curl -fsS --connect-timeout 10 --max-time 30 -X PUT \
            -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
            -d "$payload" "$API/zones/$ZONE_ID/dns_records/$record_id") || return 1
    else
        echo "มี DNS record ซ้ำหรือชนิดอื่นอยู่ที่ $host — ตรวจ/ลบ record ที่ชนใน Cloudflare DNS ก่อน แล้วรันซ้ำ" >&2
        return 1
    fi
    api_success "$result" || { jq '.errors' <<< "$result" >&2; return 1; }
}

echo "=========================================="
echo " Cloudflare Tunnel — SSH + Web Setup"
echo "=========================================="

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    fail "อย่ารันด้วย sudo/root — รัน ./setup-cloudflare.sh ด้วย user ปกติที่มี sudo"
fi

for cmd in curl jq gpg sudo; do
    command -v "$cmd" >/dev/null 2>&1 || fail "ไม่พบ $cmd — ติดตั้งด้วย: sudo apt update && sudo apt install -y $cmd"
done
if ! command -v cloudflared >/dev/null 2>&1; then
    echo "ยังไม่มี cloudflared — กำลังติดตั้งจาก Cloudflare repository ..."
    sudo install -d -m 755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/cloudflare-main.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    sudo apt update
    sudo apt install -y cloudflared
fi
[[ -f "$SCRIPT_DIR/docker-compose.yml" ]] || fail "ไม่พบ docker-compose.yml ในโฟลเดอร์โปรเจกต์ — ดาวน์โหลด/clone โปรเจกต์ใหม่แล้วลองอีกครั้ง"
sudo docker compose version >/dev/null 2>&1 || fail "ต้องติดตั้ง Docker และ Docker Compose ก่อน (รัน ./setup.sh แล้วลองใหม่)"
if ! systemctl is-active --quiet ssh; then
    fail "SSH service ยังไม่ทำงาน — รัน sudo apt install -y openssh-server && sudo systemctl enable --now ssh แล้วลองใหม่"
fi

# Load previously verified values to make a later rerun quicker.
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    [[ "${CF_ACCOUNT_ID:-}" == "xxxxxxxx" ]] && unset CF_ACCOUNT_ID
    [[ "${CF_API_TOKEN:-}" == "xxxxxxxx" ]] && unset CF_API_TOKEN
elif [[ -f "$SCRIPT_DIR/cloudflare.env.example" ]]; then
    echo "กำลังเริ่ม setup ใหม่ — ตัวอย่างค่าอยู่ใน cloudflare.env.example (สคริปต์จะถามและบันทึกให้)"
fi

read -rp "Cloudflare Account ID [${CF_ACCOUNT_ID:-}]: " INPUT_ACCOUNT_ID
CF_ACCOUNT_ID="${INPUT_ACCOUNT_ID:-${CF_ACCOUNT_ID:-}}"
read -rsp "Cloudflare API Token (Enter ใช้ค่าเดิม): " INPUT_API_TOKEN
echo ""
CF_API_TOKEN="${INPUT_API_TOKEN:-${CF_API_TOKEN:-}}"
[[ -n "$CF_ACCOUNT_ID" && -n "$CF_API_TOKEN" ]] || fail "ต้องระบุ Account ID และ API Token"
[[ "$CF_ACCOUNT_ID" =~ ^[a-fA-F0-9]{32}$ ]] || fail "Account ID ต้องเป็นเลขฐาน 16 จำนวน 32 ตัว"

read -rp "Base domain ที่เพิ่มใน Cloudflare [${CF_BASE_DOMAIN:-example.com}]: " INPUT_BASE_DOMAIN
BASE_DOMAIN="${INPUT_BASE_DOMAIN:-${CF_BASE_DOMAIN:-}}"
BASE_DOMAIN="${BASE_DOMAIN,,}"
valid_domain "$BASE_DOMAIN" || fail "รูปแบบโดเมนไม่ถูกต้อง (กรอก example.com โดยไม่ใส่ https://)"

# Require an exact, active zone in this account before creating a tunnel.
ZONES=$(api_get "$API/zones?name=$BASE_DOMAIN&status=active&per_page=50") || fail "ตรวจสอบโดเมนกับ Cloudflare ไม่สำเร็จ"
api_success "$ZONES" || { jq '.errors' <<< "$ZONES"; fail "Cloudflare ปฏิเสธคำขอตรวจสอบ Zone"; }
ZONE=$(jq -c --arg domain "$BASE_DOMAIN" --arg account "$CF_ACCOUNT_ID" \
    '[.result[] | select((.name | ascii_downcase) == $domain and .status == "active" and .account.id == $account)] | .[0] // empty' <<< "$ZONES")
[[ -n "$ZONE" ]] || fail "ไม่พบ Zone '$BASE_DOMAIN' ที่ Active ใน Account นี้ — เพิ่มโดเมนและเปลี่ยน Nameserver ให้ Cloudflare ก่อน แล้วลองใหม่"
ZONE_ID=$(jq -r '.id' <<< "$ZONE")
echo "ตรวจพบ Zone ที่ Active: $BASE_DOMAIN ✓"

read -rp "Tunnel name (เช่น my-server) [${CF_TUNNEL_NAME:-my-server}]: " INPUT_TUNNEL_NAME
TUNNEL_NAME="${INPUT_TUNNEL_NAME:-${CF_TUNNEL_NAME:-my-server}}"
[[ "$TUNNEL_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$ ]] || fail "ชื่อ Tunnel ไม่ถูกต้อง"

# Persist only verified settings for easy, repeatable future setup runs.
TMP_ENV=$(mktemp)
trap 'rm -f "$TMP_ENV"' EXIT
{
    printf '# Cloudflare Setup (auto-saved)\nCF_ACCOUNT_ID=%q\nCF_API_TOKEN=%q\nCF_BASE_DOMAIN=%q\nCF_TUNNEL_NAME=%q\n' \
        "$CF_ACCOUNT_ID" "$CF_API_TOKEN" "$BASE_DOMAIN" "$TUNNEL_NAME"
    if [[ -n "${PT_URL:-}" ]]; then printf 'PT_URL=%q\n' "$PT_URL"; fi
    if [[ -n "${PT_USER:-}" ]]; then printf 'PT_USER=%q\n' "$PT_USER"; fi
    if [[ -n "${PT_PASS:-}" ]]; then printf 'PT_PASS=%q\n' "$PT_PASS"; fi
} > "$TMP_ENV"
chmod 600 "$TMP_ENV"
mv "$TMP_ENV" "$ENV_FILE"
trap - EXIT
echo "บันทึกค่าที่ตรวจสอบแล้วใน $ENV_FILE (permission 600)"
SSH_HOSTNAME="ssh.$BASE_DOMAIN"
POSTGRES_HOSTNAME="condb.$BASE_DOMAIN"
PORTAINER_HOST="portainer.$BASE_DOMAIN"
KUMA_HOST="status.$BASE_DOMAIN"
DOZZLE_HOST="logs.$BASE_DOMAIN"

cat <<EOF

จะตั้งค่า routes/DNS ดังนี้:
  $SSH_HOSTNAME      -> ssh://localhost:22
  $POSTGRES_HOSTNAME -> tcp://localhost:55432
  $PORTAINER_HOST -> http://localhost:9000
  $KUMA_HOST    -> http://localhost:3001
  $DOZZLE_HOST     -> http://localhost:8080
EOF
read -rp "สร้าง Tunnel ใหม่และตั้งค่าตามนี้? (y/n): " CONFIRM
[[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { echo "ยกเลิก"; exit 0; }

# cloudflared login creates the account certificate. Reuse it on later runs.
echo ""
echo "[1/4] ตรวจสอบ Cloudflare login ..."
if [[ ! -f "$HOME/.cloudflared/cert.pem" ]]; then
    echo "เปิดหน้า Browser เพื่อ Login Cloudflare (เลือกบัญชีที่มี Zone: $BASE_DOMAIN)"
    cloudflared tunnel login
fi
[[ -f "$HOME/.cloudflared/cert.pem" ]] || fail "ไม่พบ cert.pem หลัง Login — ตรวจสอบว่า Login สำเร็จหรือไม่"

# Reuse a tunnel with the requested name so rerunning setup does not create duplicates.
echo "[2/4] ตรวจสอบ Tunnel ..."
TUNNELS=$(cloudflared tunnel list --output json) || fail "อ่าน Tunnel list ไม่สำเร็จ — ตรวจสอบ cert.pem หรือรัน cloudflared tunnel login"
TUNNEL_ID=$(jq -r --arg name "$TUNNEL_NAME" \
    '[.[] | select(.name == $name and (.deleted_at == null or .deleted_at == ""))] | first | .id // empty' <<< "$TUNNELS")
if [[ -n "$TUNNEL_ID" ]]; then
    echo "พบ Tunnel เดิม '$TUNNEL_NAME' ($TUNNEL_ID) — จะนำกลับมาใช้ ไม่สร้างซ้ำ"
else
    cloudflared tunnel create "$TUNNEL_NAME" || fail "สร้าง Tunnel ไม่สำเร็จ — ตรวจ Cloudflare login และดูว่า Tunnel ชื่อนี้ถูกลบ/ค้างอยู่หรือไม่"
    TUNNELS=$(cloudflared tunnel list --output json) || fail "สร้าง Tunnel แล้วแต่ดึง Tunnel list ไม่สำเร็จ"
    TUNNEL_ID=$(jq -r --arg name "$TUNNEL_NAME" \
        '[.[] | select(.name == $name)] | last | .id // empty' <<< "$TUNNELS")
fi
[[ "$TUNNEL_ID" =~ ^[a-fA-F0-9-]{36}$ ]] || fail "หา Tunnel ID ไม่ได้ — ตรวจด้วย: cloudflared tunnel list"
CRED_FILE="$HOME/.cloudflared/${TUNNEL_ID}.json"
[[ -f "$CRED_FILE" ]] || fail "ไม่พบ credentials file: $CRED_FILE — ตรวจสอบว่า Tunnel ถูกสร้างโดยบัญชี Cloudflare ที่ login อยู่"

# Check that the PostgreSQL TCP origin is reachable before adding its Tunnel route.
if ! timeout 2 bash -c ':</dev/tcp/127.0.0.1/55432' 2>/dev/null; then
    fail "PostgreSQL listener ไม่ตอบที่ localhost:55432 — เริ่ม/ตรวจ private TCP listener ก่อน แล้วจึงรัน setup อีกครั้ง"
fi

# Validate a temporary config first, keeping the active config intact on validation errors.
CONFIG_TMP=$(mktemp)
trap 'rm -f "$CONFIG_TMP"' EXIT
cat > "$CONFIG_TMP" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${SSH_HOSTNAME}
    service: ssh://localhost:22
  - hostname: ${POSTGRES_HOSTNAME}
    service: tcp://localhost:55432
  - hostname: ${PORTAINER_HOST}
    service: http://localhost:9000
  - hostname: ${KUMA_HOST}
    service: http://localhost:3001
  - hostname: ${DOZZLE_HOST}
    service: http://localhost:8080
  - service: http_status:404
EOF
cloudflared tunnel --config "$CONFIG_TMP" ingress validate || fail "Tunnel config ไม่ผ่าน validation — ยังไม่เปลี่ยน config เดิม"
sudo install -m 600 "$CONFIG_TMP" /etc/cloudflared/config.yml
rm -f "$CONFIG_TMP"
trap - EXIT

# Create/update DNS CNAME records via API. Re-running this is safe and updates old tunnel targets.
echo "[3/4] สร้าง/ตรวจสอบ DNS records ..."
for HOST in "$SSH_HOSTNAME" "$POSTGRES_HOSTNAME" "$PORTAINER_HOST" "$KUMA_HOST" "$DOZZLE_HOST"; do
    if ! ensure_dns_route "$HOST" "${TUNNEL_ID}.cfargotunnel.com"; then
        echo "[ERROR] ตั้ง DNS ไม่สำเร็จสำหรับ $HOST — ตรวจสิทธิ์ Zone:DNS Edit และแก้ record ที่ชน จากนั้นรันซ้ำได้" >&2
        exit 1
    fi
    echo "  $HOST ✓"
done

# Install systemd unit, then start the default web containers and tunnel.
echo "[4/4] เริ่ม Web services และ cloudflared ..."
sudo docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d || fail "เริ่ม Web services ไม่สำเร็จ — ตรวจ error ด้านบน แล้วรัน docker compose -f '$SCRIPT_DIR/docker-compose.yml' up -d"
if ! sudo systemctl cat cloudflared >/dev/null 2>&1; then
    sudo cloudflared service install || fail "ติดตั้ง cloudflared systemd service ไม่สำเร็จ"
fi
sudo systemctl enable cloudflared || fail "ตั้ง cloudflared ให้เริ่มพร้อมระบบไม่สำเร็จ"
sudo systemctl restart cloudflared || fail "เริ่ม cloudflared ใหม่ด้วย config ล่าสุดไม่สำเร็จ — ตรวจด้วย: sudo journalctl -u cloudflared -n 80 --no-pager"
sudo systemctl --no-pager --full status cloudflared || true

echo ""
echo "=========================================="
echo " CLOUDFLARE TUNNEL SETUP COMPLETE"
echo "=========================================="
echo "Tunnel: $TUNNEL_NAME ($TUNNEL_ID)"
echo "Routes: $SSH_HOSTNAME, $POSTGRES_HOSTNAME, $PORTAINER_HOST, $KUMA_HOST, $DOZZLE_HOST"
echo ""
echo "Web containers เริ่มแล้วจาก docker-compose.yml"
echo "ขั้นตอนถัดไปที่ต้องทำเองเพียงครั้งเดียว: ตั้ง Cloudflare Access Policy สำหรับ SSH/Web/PostgreSQL ตามต้องการ"
echo "SSH client ต้องติดตั้ง cloudflared และเพิ่มใน ~/.ssh/config:"
printf 'Host %s\n    ProxyCommand cloudflared access ssh --hostname %%h\n' "$SSH_HOSTNAME"
echo "จากนั้นเชื่อมต่อ: ssh <ubuntu-user>@$SSH_HOSTNAME"
echo "PostgreSQL: cloudflared access tcp --hostname $POSTGRES_HOSTNAME --url localhost:5432"
echo "แล้วให้ PostgreSQL client ต่อไปที่ localhost:5432 (ต้องตั้ง Access Application/Policy สำหรับ $POSTGRES_HOSTNAME)"

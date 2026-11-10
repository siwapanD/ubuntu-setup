#!/usr/bin/env bash
# ==========================================
# Ubuntu 24.04 — Outbound Proxy Setup
# ตั้ง/ถอน proxy ระบบเดียวจบ:
# shell (environment) + apt + docker daemon + docker client + snap
# ==========================================
set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ENV_FILE=/etc/environment
APT_CONF=/etc/apt/apt.conf.d/95proxy
DOCKER_OVERRIDE=/etc/systemd/system/docker.service.d/http-proxy.conf
ENV_KEYS='HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy'
NO_PROXY_DEFAULT='localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local,.internal'

banner() { echo ""; echo "=========================================="; echo " $1"; echo "=========================================="; }

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] ต้องรันด้วย sudo${NC}"
        exit 1
    fi
}

# ------------------------------------------
# ทำความสะอาด /etc/environment (ลบ key proxy เดิม)
# ------------------------------------------
clean_env_file() {
    for key in $ENV_KEYS; do
        sed -i "/^${key}=/d" "$ENV_FILE" 2>/dev/null || true
    done
}

set_env_file() {
    clean_env_file
    touch "$ENV_FILE"
    {
        echo "http_proxy=\"$PROXY\""
        echo "https_proxy=\"$PROXY\""
        echo "HTTP_PROXY=\"$PROXY\""
        echo "HTTPS_PROXY=\"$PROXY\""
        echo "no_proxy=\"$NO_PROXY\""
        echo "NO_PROXY=\"$NO_PROXY\""
    } >> "$ENV_FILE"
}

set_apt() {
    cat > "$APT_CONF" <<EOF
Acquire::http::Proxy "$PROXY";
Acquire::https::Proxy "$PROXY";
EOF
}

unset_apt() { rm -f "$APT_CONF"; }

docker_running() {
    command -v docker &>/dev/null && systemctl is-active --quiet docker
}

set_docker_daemon() {
    mkdir -p "$(dirname "$DOCKER_OVERRIDE")"
    cat > "$DOCKER_OVERRIDE" <<EOF
[Service]
Environment="HTTP_PROXY=$PROXY"
Environment="HTTPS_PROXY=$PROXY"
Environment="NO_PROXY=$NO_PROXY"
EOF
    systemctl daemon-reload
    echo -e "${YELLOW}ระบบจะ restart docker เพื่อให้ daemon ใช้ proxy (container ที่มี restart policy จะกลับมาเอง)${NC}"
    read -rp "ดำเนินการต่อ? [y/N]: " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        systemctl restart docker
        echo "docker restarted"
    else
        echo -e "${YELLOW}ข้าม restart — รันเองภายหลัง: sudo systemctl restart docker${NC}"
    fi
}

unset_docker_daemon() {
    rm -f "$DOCKER_OVERRIDE"
    rmdir "$(dirname "$DOCKER_OVERRIDE")" 2>/dev/null || true
    if docker_running; then
        systemctl daemon-reload
        systemctl restart docker
    fi
}

set_docker_client() {
    # ใส่ default proxies ให้ทุก container ที่สร้างใหม่ (ทั้ง root และ sudo user)
    local users=("/root")
    [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && users+=("$(getent passwd "$SUDO_USER" | cut -d: -f6)")
    for home in "${users[@]}"; do
        mkdir -p "$home/.docker"
        jq --arg p "$PROXY" --arg n "$NO_PROXY" \
           '.proxies = {"default": {"httpProxy": $p, "httpsProxy": $p, "noProxy": $n}}' \
           "$home/.docker/config.json" > "$home/.docker/config.json.tmp" 2>/dev/null \
           || echo "{\"proxies\":{\"default\":{\"httpProxy\":\"$PROXY\",\"httpsProxy\":\"$PROXY\",\"noProxy\":\"$NO_PROXY\"}}}" > "$home/.docker/config.json.tmp"
        mv "$home/.docker/config.json.tmp" "$home/.docker/config.json"
        [ "$(stat -c %u "$home/.docker/config.json")" != "$(id -u "${SUDO_USER:-root}")" ] && chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "$home/.docker/config.json" 2>/dev/null || true
    done
}

unset_docker_client() {
    local users=("/root")
    [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && users+=("$(getent passwd "$SUDO_USER" | cut -d: -f6)")
    for home in "${users[@]}"; do
        [ -f "$home/.docker/config.json" ] && \
        jq 'del(.proxies)' "$home/.docker/config.json" > "$home/.docker/config.json.tmp" && \
        mv "$home/.docker/config.json.tmp" "$home/.docker/config.json"
    done
}

set_snap() {
    if command -v snap &>/dev/null; then
        snap set system proxy.http="$PROXY"
        snap set system proxy.https="$PROXY"
    fi
}

unset_snap() {
    command -v snap &>/dev/null && { snap unset system proxy.http; snap unset system proxy.https; } || true
}

test_proxy() {
    banner "ทดสอบ proxy"
    if curl -sx "$PROXY" -o /dev/null -m 10 -w "%{http_code}" https://www.google.com | grep -qE '20[04]'; then
        echo -e "${GREEN}[OK] ต่ออินเทอร์เน็ตผ่าน proxy ได้${NC}"
    else
        echo -e "${RED}[ERROR] ต่อผ่าน proxy ไม่ได้ — ตรวจ URL อีกครั้ง (ไม่มีการเปลี่ยนแปลงระบบ)${NC}"
        exit 1
    fi
}

cmd_set() {
    banner "Set Outbound Proxy"
    echo "proxy : $PROXY"
    echo "no_pro: $NO_PROXY"

    test_proxy

    echo ""
    echo "[1/5] /etc/environment"
    set_env_file

    echo "[2/5] apt proxy"
    set_apt

    echo "[3/5] docker daemon (systemd override)"
    if command -v docker &>/dev/null; then set_docker_daemon; else echo "ข้าม — ไม่มี docker"; fi

    echo "[4/5] docker client (container default env)"
    command -v jq &>/dev/null && set_docker_client || { echo -e "${YELLOW}ข้าม — ต้องการ jq${NC}"; }

    echo "[5/5] snap"
    set_snap

    banner "เสร็จสิ้น"
    echo "logout/login หรือ source /etc/environment เพื่อให้ shell ปัจจุบันใช้ค่าใหม่"
}

cmd_unset() {
    banner "Unset Outbound Proxy"
    clean_env_file
    unset_apt
    command -v docker &>/dev/null && unset_docker_daemon
    command -v jq &>/dev/null && unset_docker_client
    unset_snap
    echo -e "${GREEN}[OK] ถอน proxy ครบทุกจุดแล้ว${NC}"
}

cmd_status() {
    banner "Proxy Status"
    echo "--- /etc/environment ---"
    grep -E '^https?_proxy=|^HTTP_PROXY=|^HTTPS_PROXY=|^NO_PROXY=' "$ENV_FILE" 2>/dev/null || echo "(ไม่มี)"
    echo "--- apt ---";        cat "$APT_CONF" 2>/dev/null || echo "(ไม่มี)"
    echo "--- docker daemon ---"; cat "$DOCKER_OVERRIDE" 2>/dev/null || echo "(ไม่มี)"
    echo "--- docker client ---"; jq .proxies /root/.docker/config.json 2>/dev/null || echo "(ไม่มี)"
    command -v snap &>/dev/null && { echo "--- snap ---"; snap get system proxy.http 2>/dev/null || echo "(ไม่มี)"; }
}

require_root

case "${1:-}" in
    unset)  cmd_unset ;;
    status) cmd_status ;;
    http://*|https://*) PROXY="$1"; NO_PROXY="${2:-$NO_PROXY_DEFAULT}"; cmd_set ;;
    "")     read -rp "Proxy URL (เช่น http://IP:PORT): " PROXY
            [ -z "$PROXY" ] && { echo -e "${RED}[ERROR] ไม่ได้ระบุ proxy${NC}"; exit 1; }
            NO_PROXY="${2:-$NO_PROXY_DEFAULT}"; cmd_set ;;
    *)      echo "ใช้งาน: sudo bash setup_proxy.sh <http://proxy:port> [no_proxy-list]"
            echo "       sudo bash setup_proxy.sh unset"
            echo "       sudo bash setup_proxy.sh status"
            exit 1 ;;
esac

#!/usr/bin/env bash
# ==========================================
# Credentials Loader
# โหลด Cloudflare + Portainer credentials
# source ไฟล์นี้จาก script อื่น
# ==========================================

ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/cloudflare.env"

load_cf_credentials() {
    # 1. โหลดจาก .env ก่อน
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi

    local SHOULD_SAVE=false

    # 2. Cloudflare — ถามถ้าไม่มีค่า
    if [ -z "$CF_ACCOUNT_ID" ]; then
        read -rp "Cloudflare Account ID : " CF_ACCOUNT_ID
        SHOULD_SAVE=true
    fi

    if [ -z "$CF_API_TOKEN" ]; then
        read -rsp "Cloudflare API Token  : " CF_API_TOKEN
        echo ""
        SHOULD_SAVE=true
    fi

    # 3. Portainer — ถามถ้าไม่มีค่า
    if [ -z "$PT_URL" ]; then
        PT_URL="http://localhost:9000"
    fi

    if [ -z "$PT_USER" ]; then
        read -rp "Portainer Username    : " PT_USER
        SHOULD_SAVE=true
    fi

    if [ -z "$PT_PASS" ]; then
        read -rsp "Portainer Password    : " PT_PASS
        echo ""
        SHOULD_SAVE=true
    fi

    # 4. ถามบันทึกถ้ามีค่าใหม่
    if [ "$SHOULD_SAVE" = "true" ]; then
        echo ""
        read -rp "บันทึก credentials ไว้ใช้ครั้งต่อไป? (y/n): " SAVE
        if [[ "$SAVE" == "y" || "$SAVE" == "Y" ]]; then
            cat > "$ENV_FILE" << EOF
# Cloudflare Credentials
CF_ACCOUNT_ID=${CF_ACCOUNT_ID}
CF_API_TOKEN=${CF_API_TOKEN}

# Portainer Credentials
PT_URL=${PT_URL}
PT_USER=${PT_USER}
PT_PASS=${PT_PASS}
EOF
            chmod 600 "$ENV_FILE"
            echo "บันทึกแล้วที่ $ENV_FILE ✓"
            echo "[!] ตรวจสอบว่า cloudflare.env อยู่ใน .gitignore แล้ว"
        fi
    fi

    export CF_ACCOUNT_ID CF_API_TOKEN PT_URL PT_USER PT_PASS
}
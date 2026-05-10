#!/usr/bin/env bash
# ==========================================
# Cloudflare Credentials Loader
# source ไฟล์นี้จาก script อื่น
# ==========================================

ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/cloudflare.env"

load_cf_credentials() {
    # 1. ลองอ่านจาก cloudflare.env ก่อน
    if [ -f "$ENV_FILE" ]; then
        # shellcheck source=/dev/null
        source "$ENV_FILE"
    fi

    # 2. ถ้ายังไม่มีค่า ถามผู้ใช้ แล้วถามว่าจะบันทึกไหม
    if [ -z "$CF_ACCOUNT_ID" ]; then
        read -rp "Cloudflare Account ID : " CF_ACCOUNT_ID
        SHOULD_SAVE=true
    fi

    if [ -z "$CF_API_TOKEN" ]; then
        read -rsp "Cloudflare API Token  : " CF_API_TOKEN
        echo ""
        SHOULD_SAVE=true
    fi

    # 3. ถามบันทึกสำหรับครั้งต่อไป
    if [ "${SHOULD_SAVE}" = "true" ]; then
        echo ""
        read -rp "บันทึก credentials ไว้ใช้ครั้งต่อไป? (y/n): " SAVE
        if [[ "$SAVE" == "y" || "$SAVE" == "Y" ]]; then
            cat > "$ENV_FILE" << EOF
CF_ACCOUNT_ID=${CF_ACCOUNT_ID}
CF_API_TOKEN=${CF_API_TOKEN}
EOF
            chmod 600 "$ENV_FILE"
            echo "บันทึกแล้วที่ $ENV_FILE ✓"
            echo "[!] ตรวจสอบว่า cloudflare.env อยู่ใน .gitignore แล้ว"
        fi
    fi

    # 4. export ให้ script ที่ source ใช้ได้
    export CF_ACCOUNT_ID
    export CF_API_TOKEN
}
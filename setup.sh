#!/usr/bin/env bash
# ==========================================
# Ubuntu Server 24.04 Initial Setup
# SSH First + Docker + Dev Tools
# ==========================================
set -e

echo "=========================================="
echo " Ubuntu 24.04 VM Initial Setup"
echo "=========================================="

# ------------------------------------------
# 0. SET HOSTNAME
# ------------------------------------------
echo ""
echo "[0/8] Setting hostname ..."
read -rp "Enter hostname for this server: " NEW_HOSTNAME
sudo hostnamectl set-hostname "$NEW_HOSTNAME"
sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
echo "Hostname set to: $NEW_HOSTNAME"

# ------------------------------------------
# 1. UPDATE SYSTEM
# ------------------------------------------
echo ""
echo "[1/8] Updating system ..."
sudo apt update
sudo apt upgrade -y

# ------------------------------------------
# 2. INSTALL BASIC PACKAGES
# ------------------------------------------
echo ""
echo "[2/8] Installing base packages ..."
sudo apt install -y \
    curl \
    wget \
    git \
    unzip \
    zip \
    jq \
    htop \
    btop \
    iotop \
    net-tools \
    dnsutils \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    build-essential

# ------------------------------------------
# 3. INSTALL OPENSSH SERVER
# ------------------------------------------
echo ""
echo "[3/8] Installing OpenSSH Server ..."
sudo apt install -y openssh-server
sudo systemctl enable ssh
sudo systemctl start ssh
echo "SSH STATUS:"
sudo systemctl status ssh --no-pager

# ------------------------------------------
# 4. CONFIGURE FIREWALL
# ------------------------------------------
echo ""
echo "[4/8] Configuring UFW firewall ..."
sudo apt install -y ufw
sudo ufw allow OpenSSH
sudo ufw allow 22/tcp
sudo ufw --force enable
sudo ufw status

# ------------------------------------------
# 5. INSTALL DOCKER OFFICIAL
# ------------------------------------------
echo ""
echo "[5/8] Installing Docker Engine ..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# FIX: single-line echo to avoid whitespace in .list file
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# ------------------------------------------
# 6. ENABLE DOCKER
# ------------------------------------------
echo ""
echo "[6/8] Configuring Docker ..."
sudo systemctl enable docker
sudo systemctl start docker

# FIX: use SUDO_USER fallback so docker group is added to real user
REAL_USER=${SUDO_USER:-$USER}
sudo usermod -aG docker "$REAL_USER"
echo "Added '$REAL_USER' to docker group"

echo "Docker version:"
docker --version || true

# ------------------------------------------
# 7. OPTIMIZE VM MEMORY
# ------------------------------------------
echo ""
echo "[7/8] Optimizing VM swappiness ..."
if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then
    echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

# ------------------------------------------
# 8. FINAL STATUS
# ------------------------------------------
echo ""
echo "[8/8] Final service status ..."
echo ""
echo "SSH:"
systemctl is-active ssh
echo ""
echo "Docker:"
systemctl is-active docker
echo ""
echo "Docker compose:"
docker compose version || true
echo ""
echo "=========================================="
echo " SETUP COMPLETE"
echo "=========================================="
echo ""
echo "IMPORTANT:"
echo "  - Logout/login again for docker group to take effect"
echo "  - SSH Port: 22"
echo "  - Test Docker: docker run hello-world"
echo ""

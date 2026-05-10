# 🐧 Ubuntu 24.04 Server Initial Setup

Automated setup script for a fresh Ubuntu 24.04 VM —  
installs SSH, Docker, and essential dev tools in one command.

## ✅ What It Does

| Step | Action |
|------|--------|
| 1 | System update & upgrade |
| 2 | Install base packages (curl, git, jq, htop, btop, etc.) |
| 3 | Install & enable OpenSSH Server |
| 4 | Configure UFW firewall (allow SSH port 22) |
| 5 | Install Docker Engine (official repo) |
| 6 | Enable Docker, add current user to docker group |
| 7 | Optimize VM memory (`vm.swappiness=10`) |
| 8 | Print final service status |

## 🚀 Quick Start

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/ubuntu-setup.git
cd ubuntu-setup

# Make executable and run
chmod +x setup.sh
sudo bash setup.sh
```

> After the script finishes, **logout and login again** for the Docker group to take effect.

## 📦 Installed Packages

**Base tools:**
`curl` `wget` `git` `unzip` `zip` `jq` `htop` `btop` `iotop`
`net-tools` `dnsutils` `build-essential` `gnupg` `lsb-release`

**Docker:**
`docker-ce` `docker-ce-cli` `containerd.io`
`docker-buildx-plugin` `docker-compose-plugin`

## 🔒 Firewall

UFW is enabled with SSH (port 22) allowed before the firewall activates —  
so you won't lock yourself out.

## 🧪 Test After Setup

```bash
# Test Docker
docker run hello-world

# Test Docker Compose
docker compose version

# Check SSH
systemctl status ssh
```

## 📋 Requirements

- Ubuntu 24.04 LTS (fresh install recommended)
- User with `sudo` privileges
- Internet access

## 📝 Notes

- Script uses `set -e` — stops immediately on any error
- `SUDO_USER` fallback ensures the correct user is added to the docker group (not root)
- Docker repo uses single-line `echo` to avoid whitespace issues in `.list` files
- swappiness is set to `10` only if not already configured

## 📄 License

MIT
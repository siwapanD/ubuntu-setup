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
git clone https://github.com/siwapanD/ubuntu-setup.git
cd ubuntu-setup

# Run the setup (scripts are already executable)
./setup.sh
```

> After the script finishes, **logout and login again** for the Docker group to take effect.
>
> Cloudflare Tunnel (SSH + web subdomains) is a separate one-time step. Follow the short checklist in [`docs/architecture-and-usage.md`](docs/architecture-and-usage.md#4-ติดตั้ง-cloudflare-tunnel-ให้-ssh-และ-web-ใช้งานได้). It checks the Cloudflare domain first, saves verified credentials, creates/updates DNS/routes, starts the web containers, and can be rerun later without creating duplicate tunnels.

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

## 🌐 Outbound Proxy (`setup_proxy.sh`)

Set or remove a system-wide outbound proxy in one command — covers shell, apt, Docker daemon (image pulls), Docker client (default env injected into new containers), and snap.

```bash
# Set proxy (tests connectivity first — aborts without changing anything if the proxy is unreachable)
sudo bash setup_proxy.sh http://PROXY_IP:PORT

# Custom NO_PROXY list (optional; defaults to localhost + private ranges)
sudo bash setup_proxy.sh http://PROXY_IP:PORT "localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16"

# Remove everything / show current state
sudo bash setup_proxy.sh unset
sudo bash setup_proxy.sh status
```

Files touched: `/etc/environment`, `/etc/apt/apt.conf.d/95proxy`, `/etc/systemd/system/docker.service.d/http-proxy.conf`, `~/.docker/config.json` (`proxies`), snap proxy settings.

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

## 🗄️ Nginx Proxy Manager TCP Stream for PostgreSQL

To expose PostgreSQL at `condb.itmwu.com:5432` through Nginx Proxy Manager (NPM), publish TCP port 5432 on the NPM container and configure an NPM **Stream**:

- **Incoming Port:** `5432`
- **Forward Host:** `host.docker.internal`
- **Forward Port:** `55432`
- **Protocol:** TCP

The Compose configuration maps `host.docker.internal` to the Docker host gateway, so this upstream is expected to be the PostgreSQL listener on the Ubuntu host at port `55432`. Make sure that listener is running and reachable from Docker before using the stream. Do not use an NPM HTTP Proxy Host for PostgreSQL. Alternatively, the setup script can create `condb.<base-domain>` as a Cloudflare Tunnel TCP route; that path requires client-side `cloudflared access tcp` and is separate from this public NPM stream.

Set `condb.itmwu.com` to the server's public IP with Cloudflare proxy **DNS only** (gray cloud), since standard Cloudflare proxying does not carry arbitrary PostgreSQL TCP on port 5432. Then connect with BeaverDB using `condb.itmwu.com:5432`.

**Security:** this publishes PostgreSQL to the public internet. Restrict inbound TCP/5432 to trusted client IPs in the server/cloud firewall where possible, and require PostgreSQL TLS plus strong database credentials. Do not expose the host's PostgreSQL origin port 55432 publicly; allow it only from the Docker host/network as appropriate.

## 🐳 Docker + UFW Hairpin Gotcha

UFW in this repo allows only SSH. A container that connects back to a port **published by Docker on the host itself** (e.g. `postgres` at `your-domain.com:55432` from another container) hits the host's INPUT chain and gets **dropped silently** (connection timeout) — even though the same port works fine from the internet (Docker's FORWARD path bypasses UFW).

Fix — allow Docker subnets to the published port:

```bash
ufw allow from 172.16.0.0/12 to any port 55432 proto tcp comment "docker -> host published port"
```

Alternative (no firewall change): attach both containers to the same Docker network and use the **container name + internal port** as the host (e.g. `central-postgres:5432` instead of the domain).

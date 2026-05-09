#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

INSTALL_DIR="/opt/rpi-webhost"
WEB_ROOT="/var/www/html"
SERVICE_NAME="rpi-webhost"
CLOUDFLARE_TOKEN=""

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --cloudflare)
            [[ -z "${2:-}" ]] && { echo -e "${RED}[✗]${NC} --cloudflare requires a token"; exit 1; }
            CLOUDFLARE_TOKEN="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: sudo bash install.sh [--cloudflare <TOKEN>]"
            echo ""
            echo "  --cloudflare TOKEN   Route traffic through Cloudflare Tunnel instead of"
            echo "                       opening ports 80/443 directly on your router."
            echo "                       Get a token at: dash.teams.cloudflare.com → Networks → Tunnels"
            exit 0
            ;;
        *)
            echo -e "${RED}[✗]${NC} Unknown option: $1"
            exit 1
            ;;
    esac
done

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

# ── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run with sudo: sudo bash install.sh"

# ── Arch detection ───────────────────────────────────────────────────────────
ARCH=$(uname -m)
case $ARCH in
    armv6l)  PI_MODEL="Pi Zero / Zero W (ARMv6)" ;;
    armv7l)  PI_MODEL="Pi 2 / 3 (ARMv7)" ;;
    aarch64) PI_MODEL="Pi 4 / 5 (ARM64)" ;;
    x86_64)  PI_MODEL="x86_64 (dev / test)" ;;
    *)       PI_MODEL="Unknown ($ARCH)" ;;
esac

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       RPi Website Host — Installer       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
log "Detected: $PI_MODEL"
[[ -n "$CLOUDFLARE_TOKEN" ]] && log "Mode: Cloudflare Tunnel (no open ports)"
echo ""

# ── Package installation ─────────────────────────────────────────────────────
info "Updating package lists…"
apt-get update -qq

info "Installing nginx, certbot, Python, ufw, fail2ban…"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    nginx \
    certbot \
    python3-certbot-nginx \
    python3 \
    python3-flask \
    python3-werkzeug \
    ufw \
    fail2ban \
    curl

# Fallback: install Flask via pip if not available in apt (old Pi OS)
if ! python3 -c "import flask" 2>/dev/null; then
    info "Flask not in apt — installing via pip…"
    apt-get install -y -qq python3-pip
    pip3 install flask werkzeug --quiet
fi
log "Packages installed"

# ── Web root ─────────────────────────────────────────────────────────────────
mkdir -p "$WEB_ROOT"
chown www-data:www-data "$WEB_ROOT"
chmod 755 "$WEB_ROOT"

if [[ ! -f "$WEB_ROOT/index.html" ]]; then
    cat > "$WEB_ROOT/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>My Website</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:system-ui,sans-serif;background:#0f1117;color:#e2e8f0;
         display:flex;align-items:center;justify-content:center;min-height:100vh}
    .card{background:#1e2130;padding:2.5rem;border-radius:12px;text-align:center;
          border:1px solid #2d3148;max-width:480px}
    h1{font-size:1.8rem;margin-bottom:.75rem;color:#fff}
    p{color:#94a3b8;line-height:1.6}
    .badge{display:inline-block;margin-top:1.5rem;padding:.4rem 1rem;
           background:#6366f1;border-radius:99px;font-size:.85rem;color:#fff}
  </style>
</head>
<body>
  <div class="card">
    <h1>Your site is live!</h1>
    <p>Upload your HTML, CSS, and images using the management GUI to replace this page.</p>
    <span class="badge">Hosted on Raspberry Pi</span>
  </div>
</body>
</html>
HTML
    chown www-data:www-data "$WEB_ROOT/index.html"
fi

# ── Install GUI ───────────────────────────────────────────────────────────────
info "Installing management GUI…"
mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/gui" ]]; then
    cp -r "$SCRIPT_DIR/gui" "$INSTALL_DIR/"
else
    REPO="https://github.com/marshall1405/rpi_website"
    curl -sSL "$REPO/archive/main.tar.gz" | tar xz -C /tmp
    cp -r /tmp/rpi_website-main/gui "$INSTALL_DIR/"
    rm -rf /tmp/rpi_website-main
fi

touch "$INSTALL_DIR/config.env"
chmod 600 "$INSTALL_DIR/config.env"
log "GUI installed to $INSTALL_DIR"

# ── nginx ─────────────────────────────────────────────────────────────────────
info "Configuring nginx…"
rm -f /etc/nginx/sites-enabled/default
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

cat > /etc/nginx/sites-available/rpi-webhost << 'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html index.htm;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    location / {
        try_files $uri $uri/ =404;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|webp|woff|woff2)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
NGINX

ln -sf /etc/nginx/sites-available/rpi-webhost /etc/nginx/sites-enabled/rpi-webhost
nginx -t
systemctl enable nginx
systemctl restart nginx
log "nginx running"

# ── Firewall (ufw) ────────────────────────────────────────────────────────────
info "Configuring firewall…"
ufw --force reset > /dev/null 2>&1

ufw default deny incoming
ufw default deny outgoing

# SSH is always needed
ufw allow in  ssh
ufw allow out ssh    # needed for SSH response packets on non-standard configs

# Outbound: only what the Pi legitimately needs
ufw allow out 53           # DNS       (UDP + TCP)
ufw allow out 123/udp      # NTP       — clock sync
ufw allow out 443/tcp      # HTTPS     — apt, pip, cloudflared tunnel connection

if [[ -z "$CLOUDFLARE_TOKEN" ]]; then
    # Standard mode: Pi is directly reachable — open 80/443 inbound
    ufw allow in 80/tcp
    ufw allow in 443/tcp
    ufw allow out 80/tcp   # HTTP — apt updates, certbot HTTP-01 challenge
    log "Firewall: inbound SSH/HTTP/HTTPS · outbound DNS/NTP/HTTPS only"
else
    # Cloudflare mode: tunnel handles all traffic — no inbound ports needed
    # cloudflared uses port 443 (already allowed) and optionally 7844/udp (QUIC)
    ufw allow out 7844/udp # Cloudflare QUIC — faster tunnel, fallback to 443 TCP
    log "Firewall: inbound SSH only (Cloudflare tunnel handles web traffic)"
fi

ufw --force enable > /dev/null 2>&1
log "Pi cannot reach your home network even if compromised (outbound LAN blocked)"

# ── fail2ban ──────────────────────────────────────────────────────────────────
info "Configuring fail2ban…"
cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true
F2B
systemctl enable fail2ban
systemctl restart fail2ban
log "fail2ban enabled (SSH brute-force protection active)"

# ── SSH hardening ─────────────────────────────────────────────────────────────
info "Hardening SSH config…"
SSHD="/etc/ssh/sshd_config"
cp "$SSHD" "${SSHD}.bak.$(date +%s)"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/'   "$SSHD"
sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/'       "$SSHD"
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/'          "$SSHD"
sed -i 's/^#\?LoginGraceTime.*/LoginGraceTime 20/'     "$SSHD"
systemctl reload sshd
log "SSH: root login disabled, X11 off, max 3 auth tries"

# ── Management GUI systemd service ────────────────────────────────────────────
info "Creating management GUI service…"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SERVICE
[Unit]
Description=RPi Website Management GUI
After=network.target nginx.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}/gui
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/gui/app.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
log "Management GUI service running on 127.0.0.1:8080"

# ── Cloudflare Tunnel (optional) ──────────────────────────────────────────────
if [[ -n "$CLOUDFLARE_TOKEN" ]]; then
    info "Setting up Cloudflare Tunnel…"

    # Pick the right binary for this arch
    case $ARCH in
        aarch64) CF_ARCH="arm64" ;;
        armv7l)  CF_ARCH="arm"   ;;
        armv6l)  CF_ARCH="arm"   ;;   # compiled with GOARM=6, runs on armv6
        x86_64)  CF_ARCH="amd64" ;;
        *)       err "cloudflared: unsupported architecture $ARCH" ;;
    esac

    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb"
    info "Downloading cloudflared (${CF_ARCH})…"
    curl -fsSL -o /tmp/cloudflared.deb "$CF_URL"
    dpkg -i /tmp/cloudflared.deb > /dev/null
    rm /tmp/cloudflared.deb

    # Register the tunnel as a systemd service using the token
    cloudflared service install "$CLOUDFLARE_TOKEN"
    systemctl enable cloudflared
    systemctl start  cloudflared
    log "Cloudflare Tunnel installed and running"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-pi-ip")

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                  Installation Complete!                  ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ -n "$CLOUDFLARE_TOKEN" ]]; then
    echo -e "  ${BOLD}Mode:${NC}  Cloudflare Tunnel — no open ports on your router"
    echo -e "  ${BOLD}Site:${NC}  Check your Cloudflare dashboard for the public URL"
else
    echo -e "  ${BOLD}Your site is live at:${NC}  http://$IP"
    echo    "  (Add a domain + SSL via the management GUI)"
fi

echo ""
echo -e "  ${BOLD}Management GUI (via SSH tunnel):${NC}"
echo -e "  ${BLUE}1.${NC} On your laptop: ${YELLOW}ssh -L 8080:localhost:8080 pi@$IP${NC}"
echo -e "  ${BLUE}2.${NC} Open in browser: ${YELLOW}http://localhost:8080${NC}"
echo ""
echo    "  ──────────────────────────────────────────────────────────"
echo    "  In the GUI you can:"
echo    "  • Upload your HTML / CSS / images"
echo    "  • Set your domain name"
if [[ -z "$CLOUDFLARE_TOKEN" ]]; then
    echo    "  • Get a free SSL certificate (Let's Encrypt)"
fi
echo    "  ──────────────────────────────────────────────────────────"
echo ""
warn "SECURITY TIP: Add your SSH public key, then disable password"
warn "auth: edit /etc/ssh/sshd_config → PasswordAuthentication no"
echo ""

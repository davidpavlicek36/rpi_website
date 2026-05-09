#!/usr/bin/env bash
set -euo pipefail

# Suppress locale warnings (Mac SSH forwards LC_CTYPE=UTF-8 which Perl rejects on Pi)
export LC_ALL=C
export LANG=C

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
BOLD='\033[1m'

INSTALL_DIR="/opt/rpi-webhost"
WEB_ROOT="/var/www/html"
SERVICE_NAME="rpi-webhost"
SERVICE_USER="rpi-webhost"
STEP=0

# ── Output helpers ────────────────────────────────────────────────────────────
log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
err()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()    { echo -e "${BLUE}[→]${NC} $1"; }
skip()    { echo -e "${YELLOW}[↷]${NC} Already done: $1 — skipping"; }
detail()  { echo -e "    $1"; }

step() {
    STEP=$((STEP + 1))
    echo ""
    echo -e "${BOLD}── Step ${STEP}: $1 ──────────────────────────────────${NC}"
}

# ── Token input: env var (preferred) or --token-file ─────────────────────────
# Do NOT pass the token as a bare CLI argument — it ends up in shell history
# and briefly visible in `ps`. Use one of:
#   sudo CF_TOKEN=<token> bash install.sh
#   sudo bash install.sh --token-file /path/with/600/perms

CLOUDFLARE_TOKEN="${CF_TOKEN:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --token-file)
            [[ -z "${2:-}" ]] && err "--token-file requires a path"
            [[ ! -f "$2" ]]   && err "Token file not found: $2"
            CLOUDFLARE_TOKEN="$(< "$2")"
            [[ -z "$CLOUDFLARE_TOKEN" ]] && err "Token file is empty: $2"
            shift 2 ;;
        -h|--help)
            echo "Usage:"
            echo "  sudo CF_TOKEN=<token> bash install.sh"
            echo "  sudo bash install.sh --token-file /path/to/token-file"
            echo ""
            echo "Get a token: dash.teams.cloudflare.com → Networks → Tunnels → Create tunnel"
            exit 0 ;;
        *)
            err "Unknown option: $1" ;;
    esac
done

[[ -z "$CLOUDFLARE_TOKEN" ]] && err \
    "Cloudflare tunnel token required.\n\n  sudo CF_TOKEN=<token> bash install.sh\n\nGet one at: dash.teams.cloudflare.com → Networks → Tunnels"

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run with sudo: sudo CF_TOKEN=<token> bash install.sh"

# ── Arch detection ────────────────────────────────────────────────────────────
ARCH=$(uname -m)
case $ARCH in
    armv6l)  PI_MODEL="Pi Zero / Zero W (ARMv6)" ;;
    armv7l)  PI_MODEL="Pi 2 / 3 (ARMv7)"         ;;
    aarch64) PI_MODEL="Pi 4 / 5 (ARM64)"          ;;
    x86_64)  PI_MODEL="x86_64 (dev / test)"       ;;
    *)       PI_MODEL="Unknown ($ARCH)"            ;;
esac

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       RPi Website Host — Installer       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
log "Detected: $PI_MODEL ($ARCH)"
log "Mode: Cloudflare Tunnel (no open router ports)"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
step "System locale"
# ─────────────────────────────────────────────────────────────────────────────
LOCALE="en_GB.UTF-8"
if locale -a 2>/dev/null | grep -qi "en_GB.utf8"; then
    skip "locale $LOCALE (already generated)"
else
    info "Generating $LOCALE locale…"
    sed -i "s/^# *${LOCALE}/${LOCALE}/" /etc/locale.gen
    locale-gen "$LOCALE"
    update-locale LANG="$LOCALE" LC_ALL="$LOCALE"
    log "Locale $LOCALE generated"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "System packages"
# ─────────────────────────────────────────────────────────────────────────────
# certbot/python3-certbot-nginx omitted — Cloudflare handles SSL at the edge
PKGS=(nginx python3 python3-flask python3-werkzeug ufw fail2ban curl)
PKGS_MISSING=()
for pkg in "${PKGS[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        detail "${pkg}: already installed"
    else
        detail "${pkg}: will install"
        PKGS_MISSING+=("$pkg")
    fi
done

if [[ ${#PKGS_MISSING[@]} -eq 0 ]]; then
    skip "all packages"
else
    echo ""
    info "Updating package lists…"
    apt-get update

    info "Installing missing packages: ${PKGS_MISSING[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS_MISSING[@]}"
    log "Packages installed"
fi

if ! python3 -c "import flask" 2>/dev/null; then
    info "Flask not importable — installing via pip…"
    apt-get install -y python3-pip
    pip3 install flask werkzeug
    log "Flask installed via pip"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Service user (least-privilege)"
# ─────────────────────────────────────────────────────────────────────────────
if id "$SERVICE_USER" &>/dev/null; then
    skip "user $SERVICE_USER (already exists)"
else
    info "Creating system user $SERVICE_USER…"
    useradd --system --no-create-home --shell /usr/sbin/nologin -G adm "$SERVICE_USER"
    log "User $SERVICE_USER created"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Web root"
# ─────────────────────────────────────────────────────────────────────────────
if [[ -d "$WEB_ROOT" ]]; then
    skip "web root $WEB_ROOT"
else
    info "Creating $WEB_ROOT…"
    mkdir -p "$WEB_ROOT"
    log "Web root created"
fi

# Service user owns web root so it can write uploads without root
chown -R "${SERVICE_USER}:www-data" "$WEB_ROOT"
chmod 755 "$WEB_ROOT"

if [[ -f "$WEB_ROOT/index.html" ]]; then
    skip "default index.html (your file is already there)"
else
    info "Writing default landing page…"
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
    chown "${SERVICE_USER}:www-data" "$WEB_ROOT/index.html"
    log "Default landing page written"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Management GUI"
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "$INSTALL_DIR/gui/app.py" ]]; then
    skip "GUI files (already at $INSTALL_DIR/gui)"
else
    info "Copying GUI files to $INSTALL_DIR…"
    mkdir -p "$INSTALL_DIR"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$SCRIPT_DIR/gui" ]]; then
        detail "Source: local clone at $SCRIPT_DIR"
        cp -r "$SCRIPT_DIR/gui" "$INSTALL_DIR/"
    else
        detail "Source: downloading from GitHub…"
        REPO="https://github.com/davidpavlicek36/rpi_website"
        curl -fsSL --progress-bar "$REPO/archive/main.tar.gz" | tar xz -C /tmp
        cp -r /tmp/rpi_website-main/gui "$INSTALL_DIR/"
        rm -rf /tmp/rpi_website-main
    fi
    log "GUI files installed"
fi

# Service user owns the install dir (config, secret key)
chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"

if [[ ! -f "$INSTALL_DIR/config.env" ]]; then
    touch "$INSTALL_DIR/config.env"
    chown "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR/config.env"
    chmod 600 "$INSTALL_DIR/config.env"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "nginx"
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f /etc/nginx/sites-available/rpi-webhost ]]; then
    skip "nginx site config"
else
    info "Writing nginx site config…"
    rm -f /etc/nginx/sites-enabled/default
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    cat > /etc/nginx/sites-available/rpi-webhost << 'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html index.htm;

    # Real visitor IP from Cloudflare Tunnel (traffic arrives from localhost)
    set_real_ip_from 127.0.0.1;
    real_ip_header CF-Connecting-IP;
    real_ip_recursive on;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

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
    log "nginx config written"
fi

info "Testing nginx config…"
nginx -t
info "Enabling and restarting nginx…"
systemctl enable nginx
systemctl restart nginx
log "nginx is running"

# ─────────────────────────────────────────────────────────────────────────────
step "Public DNS (required for LAN isolation)"
# ─────────────────────────────────────────────────────────────────────────────
# We block RFC1918 outbound below, which would break DNS if the router
# (192.168.x.x) is the resolver. Switch to Cloudflare's public DNS first.

if systemctl is-active NetworkManager &>/dev/null; then
    info "NetworkManager detected (Bookworm) — configuring via nmcli…"
    ACTIVE_CON=$(nmcli -t -f NAME con show --active 2>/dev/null | head -1)
    if [[ -n "$ACTIVE_CON" ]]; then
        nmcli con mod "$ACTIVE_CON" ipv4.dns "1.1.1.1 1.0.0.1"
        nmcli con mod "$ACTIVE_CON" ipv4.ignore-auto-dns yes
        nmcli con up "$ACTIVE_CON" > /dev/null 2>&1 || true
        log "NetworkManager set to Cloudflare DNS (survives reboots)"
    else
        warn "Could not detect active connection — skipping nmcli DNS config"
    fi
elif [[ -f /etc/dhcpcd.conf ]]; then
    if grep -q "static domain_name_servers" /etc/dhcpcd.conf; then
        skip "dhcpcd DNS config (already set)"
    else
        info "dhcpcd detected (Bullseye) — configuring…"
        echo "static domain_name_servers=1.1.1.1 1.0.0.1" >> /etc/dhcpcd.conf
        systemctl restart dhcpcd 2>/dev/null || true
        log "dhcpcd set to Cloudflare DNS (survives reboots)"
    fi
else
    warn "No known network manager found — DNS may revert after reboot"
fi

# Apply immediately regardless of network manager
info "Applying Cloudflare DNS to resolv.conf now…"
{
    echo "nameserver 1.1.1.1"
    echo "nameserver 1.0.0.1"
} > /etc/resolv.conf
log "DNS set to 1.1.1.1 — router DNS no longer needed"

# ─────────────────────────────────────────────────────────────────────────────
step "Firewall (ufw)"
# ─────────────────────────────────────────────────────────────────────────────
info "Resetting firewall rules…"
ufw --force reset > /dev/null 2>&1

info "Setting default policies (deny all in/out)…"
ufw default deny incoming
ufw default deny outgoing

info "Allowing inbound SSH…"
ufw allow in ssh

# Block RFC1918 outbound BEFORE the port-based allows so the Pi cannot
# scan or reach LAN devices (NAS, router admin, IoT panels, etc.)
info "Blocking outbound RFC1918 + IPv6 private ranges (LAN isolation)…"
ufw deny out to 10.0.0.0/8
ufw deny out to 172.16.0.0/12
ufw deny out to 192.168.0.0/16
ufw deny out to fc00::/7    # IPv6 ULA (private, equivalent of RFC1918)
ufw deny out to fe80::/10   # IPv6 link-local

info "Allowing outbound internet traffic (DNS, NTP, HTTPS, Cloudflare QUIC)…"
ufw allow out 53        # DNS — to 1.1.1.1 (RFC1918 already denied above)
ufw allow out 123/udp   # NTP clock sync
ufw allow out 443/tcp   # HTTPS — apt, pip, cloudflared
ufw allow out 7844/udp  # Cloudflare QUIC (fallback tunnel transport)

info "Enabling firewall…"
ufw --force enable > /dev/null 2>&1

log "Firewall active — Pi is LAN-isolated"
ufw status verbose
echo ""

# ─────────────────────────────────────────────────────────────────────────────
step "fail2ban (brute-force protection)"
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f /etc/fail2ban/jail.local ]]; then
    skip "fail2ban config (jail.local already exists)"
else
    info "Writing fail2ban jail config…"
    cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
F2B
    log "fail2ban config written"
fi

info "Enabling fail2ban service…"
systemctl enable fail2ban
info "Starting fail2ban…"
systemctl restart fail2ban
log "fail2ban running (bans IPs after 5 failed SSH attempts in 10 min)"

# ─────────────────────────────────────────────────────────────────────────────
step "SSH hardening"
# ─────────────────────────────────────────────────────────────────────────────
SSHD="/etc/ssh/sshd_config"

if grep -q "^PermitRootLogin no" "$SSHD" 2>/dev/null; then
    skip "SSH hardening (already applied)"
else
    info "Backing up $SSHD → ${SSHD}.bak.$(date +%s)"
    cp "$SSHD" "${SSHD}.bak.$(date +%s)"

    info "Disabling root login…"
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD"
    info "Disabling X11 forwarding…"
    sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' "$SSHD"
    info "Setting max auth tries to 3…"
    sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$SSHD"
    info "Setting login grace time to 20 s…"
    sed -i 's/^#\?LoginGraceTime.*/LoginGraceTime 20/' "$SSHD"

    info "Reloading SSH daemon…"
    systemctl reload sshd
    log "SSH hardened"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Sudoers (least-privilege tunnel restart)"
# ─────────────────────────────────────────────────────────────────────────────
SUDOERS_FILE="/etc/sudoers.d/rpi-webhost"
if [[ -f "$SUDOERS_FILE" ]]; then
    skip "sudoers file (already exists)"
else
    info "Writing sudoers entries for $SERVICE_USER…"
    cat > "$SUDOERS_FILE" << 'SUDOERS'
# Tunnel restart — explicit path works on both Bullseye (/bin) and Bookworm (/usr/bin)
rpi-webhost ALL=(root) NOPASSWD: /usr/bin/systemctl restart cloudflared
rpi-webhost ALL=(root) NOPASSWD: /usr/bin/systemctl status cloudflared
# Log reading — scoped to nginx logs only, no adm group needed
rpi-webhost ALL=(root) NOPASSWD: /usr/bin/tail -n 80 -f /var/log/nginx/access.log
rpi-webhost ALL=(root) NOPASSWD: /usr/bin/tail -n 80 -f /var/log/nginx/error.log
SUDOERS
    chmod 440 "$SUDOERS_FILE"
    log "Sudoers configured — GUI may only restart/status cloudflared"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Management GUI service"
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    skip "GUI service file (already exists)"
else
    info "Writing systemd service file…"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SERVICE
[Unit]
Description=RPi Website Management GUI
After=network.target nginx.service

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}/gui
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/gui/app.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE
    log "Service file written (running as $SERVICE_USER, not root)"
fi

info "Reloading systemd daemon…"
systemctl daemon-reload
info "Enabling GUI service…"
systemctl enable "$SERVICE_NAME"
info "Starting GUI service…"
systemctl restart "$SERVICE_NAME"
log "Management GUI running on 127.0.0.1:8080"

# ─────────────────────────────────────────────────────────────────────────────
step "Cloudflare Tunnel"
# ─────────────────────────────────────────────────────────────────────────────
if systemctl is-active cloudflared &>/dev/null; then
    skip "cloudflared (service already running)"
    warn "To re-register with a new token:"
    warn "  sudo cloudflared service uninstall"
    warn "  sudo CF_TOKEN=<NEW_TOKEN> bash install.sh"
else
    case $ARCH in
        aarch64) CF_METHOD="deb";    CF_ARCH="arm64" ;;
        x86_64)  CF_METHOD="deb";    CF_ARCH="amd64" ;;
        armv7l)  CF_METHOD="binary"; CF_ARCH="arm"   ;;
        armv6l)  CF_METHOD="binary"; CF_ARCH="arm"   ;;
        *)       err "cloudflared: unsupported architecture $ARCH" ;;
    esac

    CF_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"

    if command -v cloudflared &>/dev/null; then
        skip "cloudflared binary (already installed: $(cloudflared --version 2>&1 | head -1))"
    else
        if [[ "$CF_METHOD" == "deb" ]]; then
            CF_URL="${CF_BASE}/cloudflared-linux-${CF_ARCH}.deb"
            info "Downloading cloudflared .deb for ${CF_ARCH}…"
            detail "This may take a few minutes — you will see a progress bar"
            echo ""
            curl -fsSL --progress-bar -o /tmp/cloudflared.deb "$CF_URL"
            echo ""
            info "Installing cloudflared package…"
            dpkg -i /tmp/cloudflared.deb
            rm /tmp/cloudflared.deb
        else
            # 32-bit ARM: Cloudflare's .deb is armel but Raspberry Pi OS is armhf
            CF_URL="${CF_BASE}/cloudflared-linux-${CF_ARCH}"
            info "Downloading cloudflared binary for ${CF_ARCH} (32-bit ARM, raw binary)…"
            detail "Note: using raw binary — armhf is incompatible with the .deb package"
            detail "This may take a few minutes on Pi Zero — you will see a progress bar"
            echo ""
            curl -fsSL --progress-bar -o /usr/local/bin/cloudflared "$CF_URL"
            echo ""
            chmod +x /usr/local/bin/cloudflared
        fi
        log "cloudflared installed ($(cloudflared --version 2>&1 | head -1))"
    fi

    info "Registering tunnel with Cloudflare…"
    detail "This takes 10–30 seconds…"
    cloudflared service install "$CLOUDFLARE_TOKEN"
    info "Enabling cloudflared service…"
    systemctl enable cloudflared
    info "Starting cloudflared…"
    systemctl start cloudflared
    log "Cloudflare Tunnel installed and running"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-pi-ip")

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                  Installation Complete!                  ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Mode:${NC}  Cloudflare Tunnel — no open ports on your router"
echo -e "  ${BOLD}Site:${NC}  Configure a Public Hostname in Cloudflare Zero Trust:"
echo    "         dash.cloudflare.com → Zero Trust → Networks → Tunnels"
echo    "         Public Hostname → http://localhost:80"
echo ""
echo -e "  ${BOLD}Management GUI — SSH tunnel from your laptop:${NC}"
echo -e "  ${BLUE}1.${NC} ${YELLOW}ssh -L 8080:localhost:8080 pi@$IP${NC}"
echo -e "  ${BLUE}2.${NC} Open ${YELLOW}http://localhost:8080${NC} in your browser"
echo ""
echo    "  ──────────────────────────────────────────────────────────"
warn "SECURITY: Add your SSH key, then disable password auth:"
warn "  ssh-copy-id pi@$IP"
warn "  sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
warn "  sudo systemctl reload sshd"
echo ""

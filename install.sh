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
# \033[0G resets cursor to column 0 — prevents apt/ufw \r sequences from
# leaving the cursor mid-line and making our output appear indented
R=$'\033[0G'
log()     { printf '%s' "$R"; echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { printf '%s' "$R"; echo -e "${YELLOW}[!]${NC} $1"; }
err()     { printf '%s' "$R"; echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()    { printf '%s' "$R"; echo -e "${BLUE}[→]${NC} $1"; }
skip()    { printf '%s' "$R"; echo -e "${YELLOW}[↷]${NC} Already done: $1 — skipping"; }
detail()  { printf '%s' "$R"; echo -e "    $1"; }

step() {
    STEP=$((STEP + 1))
    printf '%s\n' "$R"
    echo -e "${BOLD}── Step ${STEP}: $1 ──────────────────────────────────${NC}"
}

# ── Diagnostic helpers ────────────────────────────────────────────────────────

# Run a command with a timeout; on failure print a hint and exit
# Usage: guarded <seconds> <hint> <cmd> [args...]
guarded() {
    local secs=$1 hint=$2; shift 2
    if ! timeout "$secs" "$@"; then
        echo ""
        err "$hint"
    fi
}

# Verify a systemd service is active after starting it; dump recent logs if not
assert_service() {
    local svc=$1
    sleep 2
    if ! systemctl is-active "$svc" &>/dev/null; then
        echo ""
        warn "Service '$svc' failed to start. Recent logs:"
        journalctl -u "$svc" -n 15 --no-pager 2>/dev/null || true
        echo ""
        err "Service '$svc' did not come up. Fix the error above, then re-run the installer."
    fi
}

# ── Cloudflare API helpers ────────────────────────────────────────────────────

# Make a Cloudflare API call; returns the response body
# Usage: cf_api <METHOD> <endpoint> [json-body]
cf_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-sS -X "$method"
        "https://api.cloudflare.com/client/v4${endpoint}"
        -H "Authorization: Bearer ${CF_API_TOKEN}"
        -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}"
}

# Extract a field from a JSON API response using python3
cf_json() { python3 -c "import sys,json; d=json.load(sys.stdin); $1" 2>/dev/null; }

# Create or update a proxied CNAME record
dns_upsert() {
    local zone_id="$1" name="$2" content="$3"
    local existing record_id
    existing=$(cf_api GET "/zones/${zone_id}/dns_records?type=CNAME&name=${name}")
    record_id=$(echo "$existing" | cf_json "r=d.get('result',[]); print(r[0]['id'] if r else '')")
    if [[ -n "$record_id" ]]; then
        cf_api PATCH "/zones/${zone_id}/dns_records/${record_id}" \
            "{\"content\":\"${content}\",\"proxied\":true}" > /dev/null
    else
        cf_api POST "/zones/${zone_id}/dns_records" \
            "{\"type\":\"CNAME\",\"name\":\"${name}\",\"content\":\"${content}\",\"proxied\":true}" > /dev/null
    fi
}

# ── Token input: env var (preferred) or --token-file ─────────────────────────
# Do NOT pass the token as a bare CLI argument — it ends up in shell history
# and briefly visible in `ps`. Use one of:
#   sudo CF_TOKEN=<token> bash install.sh
#   sudo bash install.sh --token-file /path/with/600/perms

CLOUDFLARE_TOKEN="${CF_TOKEN:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
DOMAIN="${DOMAIN:-}"

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
            echo "  sudo CF_TOKEN=<token> CF_API_TOKEN=<api-token> DOMAIN=yourdomain.com bash install.sh"
            echo ""
            echo "  CF_TOKEN      — tunnel token from Zero Trust → Networks → Tunnels"
            echo "  CF_API_TOKEN  — API token with DNS:Edit + Cloudflare Tunnel:Edit permissions"
            echo "  DOMAIN        — your domain (e.g. example.com) — required with CF_API_TOKEN"
            exit 0 ;;
        *)
            err "Unknown option: $1" ;;
    esac
done

[[ -z "$CLOUDFLARE_TOKEN" ]] && err \
    "Cloudflare tunnel token required.\n\n  sudo CF_TOKEN=<token> bash install.sh\n\nGet one at: dash.teams.cloudflare.com → Networks → Tunnels"

if [[ -n "$CF_API_TOKEN" && -z "$DOMAIN" ]]; then
    err "DOMAIN is required when CF_API_TOKEN is set.\n  Example: sudo CF_TOKEN=<t> CF_API_TOKEN=<a> DOMAIN=example.com bash install.sh"
fi

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
step "Pre-flight checks"
# ─────────────────────────────────────────────────────────────────────────────

info "Checking internet connectivity…"
if ! timeout 10 curl -fsSL --max-time 8 -o /dev/null https://1.1.1.1 2>/dev/null; then
    err "No internet connection detected.\n  The Pi must be online to install packages and reach Cloudflare.\n  Check your WiFi / ethernet cable and try again."
fi
log "Internet connection confirmed"

info "Checking iptables backend…"
if ! iptables -L &>/dev/null 2>&1; then
    warn "iptables not available — attempting to install…"
    apt-get install -y iptables > /dev/null 2>&1 || err "Could not install iptables. Run: sudo apt-get install iptables"
fi
# Detect nftables/iptables mismatch (common cause of ufw hanging on Bullseye)
if iptables --version 2>/dev/null | grep -q "nf_tables"; then
    info "nftables backend detected — switching to iptables-legacy to prevent ufw hang…"
    update-alternatives --set iptables  /usr/sbin/iptables-legacy  2>/dev/null || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    log "iptables-legacy set as default"
else
    log "iptables backend OK"
fi

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
    if ! timeout 120 apt-get update -yqq > /dev/null 2>&1; then
        err "apt-get update failed.\n  Possible causes:\n  - No internet (already checked, may have dropped)\n  - Corrupt package lists: run 'sudo rm -rf /var/lib/apt/lists/*' and retry\n  - apt lock held by another process: wait a minute and retry"
    fi

    info "Installing: ${PKGS_MISSING[*]} (this may take a few minutes…)"
    ( printf '.'; while true; do sleep 2; printf '.'; done ) &
    APT_DOTS=$!
    timeout 300 env DEBIAN_FRONTEND=noninteractive apt-get install -yqq "${PKGS_MISSING[@]}" > /dev/null 2>&1 || true
    kill $APT_DOTS 2>/dev/null; wait $APT_DOTS 2>/dev/null || true; printf '\n'

    # Verify packages actually landed — apt can exit non-zero for harmless reasons
    FAILED=()
    for pkg in "${PKGS_MISSING[@]}"; do
        dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' || FAILED+=("$pkg")
    done
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        err "The following packages failed to install: ${FAILED[*]}\n  Try running manually: sudo apt-get install -y ${FAILED[*]}\n  If you see 'dpkg was interrupted', run: sudo dpkg --configure -a"
    fi
    log "Packages installed"
fi

if ! python3 -c "import flask" 2>/dev/null; then
    info "Flask not importable — installing via pip…"
    apt-get install -y python3-pip
    pip3 install flask werkzeug
    log "Flask installed via pip"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Automatic security updates"
# ─────────────────────────────────────────────────────────────────────────────

# unattended-upgrades applies apt security patches nightly (nginx, system libs)
if dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
    skip "unattended-upgrades (already installed)"
else
    info "Installing unattended-upgrades…"
    ( printf '.'; while true; do sleep 2; printf '.'; done ) &
    APT_DOTS=$!
    timeout 120 env DEBIAN_FRONTEND=noninteractive apt-get install -yqq unattended-upgrades > /dev/null 2>&1 || true
    kill $APT_DOTS 2>/dev/null; wait $APT_DOTS 2>/dev/null || true; printf '\n'
    if dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
        log "unattended-upgrades installed"
    else
        warn "Failed to install unattended-upgrades — automatic apt updates will not run. Non-fatal, continuing…"
    fi
fi

AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"
if [[ -f "$AUTO_UPGRADES" ]]; then
    skip "auto-upgrades config (already exists)"
else
    info "Enabling nightly security updates…"
    cat > "$AUTO_UPGRADES" << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    log "Nightly security updates enabled (nginx + system packages)"
fi

# cloudflared weekly update cron job (runs every Sunday at 3am)
# PATH ensures the binary is found regardless of install location
CRON_JOB="0 3 * * 0 PATH=/usr/local/bin:/usr/bin:/bin cloudflared update > /dev/null 2>&1 && systemctl restart cloudflared > /dev/null 2>&1"
if crontab -l 2>/dev/null | grep -q "cloudflared update"; then
    skip "cloudflared update cron job (already exists)"
else
    info "Adding weekly cloudflared update cron job…"
    if { crontab -l 2>/dev/null; echo "$CRON_JOB"; } | timeout 10 crontab -; then
        log "cloudflared will auto-update every Sunday at 3am"
    else
        warn "Could not add cron job — add manually: sudo crontab -e"
    fi
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
        if ! timeout 60 curl -fsSL --progress-bar "$REPO/archive/main.tar.gz" | tar xz -C /tmp; then
            err "Failed to download GUI files from GitHub.\n  Check your internet connection or clone the repo manually:\n  git clone $REPO && cd rpi_website && sudo CF_TOKEN=<token> bash install.sh"
        fi
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
if ! nginx -t 2>/tmp/nginx-test.log; then
    cat /tmp/nginx-test.log
    err "nginx config test failed (see above).\n  Edit /etc/nginx/sites-available/rpi-webhost to fix the error, then re-run."
fi

info "Enabling and restarting nginx…"
systemctl enable nginx
if ! timeout 30 systemctl restart nginx; then
    warn "nginx restart timed out or failed. Logs:"
    journalctl -u nginx -n 10 --no-pager 2>/dev/null || true
    err "nginx failed to start.\n  Run 'sudo nginx -t' for details."
fi
assert_service nginx
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

info "Verifying DNS resolution works…"
if ! timeout 10 curl -fsSL --max-time 8 -o /dev/null https://1.1.1.1 2>/dev/null; then
    err "DNS/connectivity check failed after switching to 1.1.1.1.\n  This usually means outbound port 443 is blocked on your network.\n  Check your router/firewall settings and try again."
fi
log "DNS resolution confirmed (1.1.1.1 reachable)"

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

info "Enabling firewall… (may take up to 60 s — Pi is still working)"
( printf '.'; while true; do sleep 2; printf '.'; done ) &
DOTS_PID=$!
UFW_RC=0
timeout 45 ufw --force enable > /dev/null 2>&1 || UFW_RC=$?
kill $DOTS_PID 2>/dev/null; wait $DOTS_PID 2>/dev/null || true; printf '\n'

if [[ $UFW_RC -ne 0 ]]; then
    warn "ufw enable timed out — applying iptables-legacy fix…"
    update-alternatives --set iptables  /usr/sbin/iptables-legacy  2>/dev/null || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    ( printf '.'; while true; do sleep 2; printf '.'; done ) &
    DOTS_PID=$!
    UFW_RC2=0
    timeout 30 ufw --force enable > /dev/null 2>&1 || UFW_RC2=$?
    kill $DOTS_PID 2>/dev/null; wait $DOTS_PID 2>/dev/null || true; printf '\n'
    if [[ $UFW_RC2 -ne 0 ]]; then
        err "Firewall still failed to enable after iptables-legacy fix.\n  Run manually: sudo update-alternatives --set iptables /usr/sbin/iptables-legacy\n  Then: sudo ufw --force enable"
    fi
    log "iptables-legacy applied and firewall enabled"
fi

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

info "Enabling and starting fail2ban…"
systemctl enable fail2ban
if ! timeout 30 systemctl restart fail2ban; then
    warn "fail2ban failed to start — SSH brute-force protection is inactive."
    warn "Run 'sudo systemctl status fail2ban' for details. This is non-fatal, continuing…"
else
    assert_service fail2ban
    log "fail2ban running (bans IPs after 5 failed SSH attempts in 10 min)"
fi

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

    info "Validating sshd config before reload…"
    if ! sshd -t 2>/tmp/sshd-test.log; then
        cat /tmp/sshd-test.log
        warn "sshd config has errors — restoring backup to avoid locking you out"
        cp "${SSHD}.bak."* "$SSHD" 2>/dev/null || true
        err "SSH config validation failed (see above). Original config restored."
    fi

    info "Reloading SSH daemon…"
    if ! timeout 15 systemctl reload sshd; then
        err "sshd reload failed.\n  Your SSH session is still active but hardening was not applied.\n  Run 'sudo systemctl status sshd' for details."
    fi
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

    info "Validating sudoers file…"
    if ! visudo -cf "$SUDOERS_FILE" > /dev/null 2>&1; then
        rm -f "$SUDOERS_FILE"
        err "sudoers file failed validation and was removed. This is a bug — please report it."
    fi
    log "Sudoers configured"
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
if ! timeout 15 systemctl restart "$SERVICE_NAME"; then
    warn "GUI service failed to start. Logs:"
    journalctl -u "$SERVICE_NAME" -n 15 --no-pager 2>/dev/null || true
    err "Management GUI did not start.\n  Common causes:\n  - Flask not installed (run: pip3 install flask werkzeug)\n  - Permission error on $INSTALL_DIR (run: sudo chown -R $SERVICE_USER $INSTALL_DIR)\n  - Python error in app.py (run: sudo -u $SERVICE_USER python3 $INSTALL_DIR/gui/app.py)"
fi
assert_service "$SERVICE_NAME"
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
            if ! timeout 180 curl -fsSL --progress-bar -o /tmp/cloudflared.deb "$CF_URL"; then
                err "Failed to download cloudflared.\n  Check your internet connection and try again."
            fi
            echo ""
            info "Installing cloudflared package…"
            if ! dpkg -i /tmp/cloudflared.deb; then
                rm -f /tmp/cloudflared.deb
                err "cloudflared package install failed.\n  Run 'sudo apt-get install -f' to fix broken dependencies, then retry."
            fi
            rm /tmp/cloudflared.deb
        else
            # 32-bit ARM: Cloudflare's .deb is armel but Raspberry Pi OS is armhf
            CF_URL="${CF_BASE}/cloudflared-linux-${CF_ARCH}"
            info "Downloading cloudflared binary for ${CF_ARCH} (32-bit ARM, raw binary)…"
            detail "Note: using raw binary — armhf is incompatible with the .deb package"
            detail "This may take a few minutes on Pi Zero — you will see a progress bar"
            echo ""
            if ! timeout 300 curl -fsSL --progress-bar -o /usr/local/bin/cloudflared "$CF_URL"; then
                err "Failed to download cloudflared binary.\n  Check your internet connection and try again."
            fi
            echo ""
            chmod +x /usr/local/bin/cloudflared
        fi
        log "cloudflared installed ($(cloudflared --version 2>&1 | head -1))"
    fi

    info "Registering tunnel with Cloudflare… (10–30 s)"
    if ! timeout 60 cloudflared service install "$CLOUDFLARE_TOKEN"; then
        err "cloudflared tunnel registration failed.\n  Common causes:\n  - Invalid or expired token — get a new one at dash.teams.cloudflare.com → Networks → Tunnels\n  - No outbound internet on port 443 (check firewall / router)"
    fi

    info "Enabling cloudflared service…"
    systemctl enable cloudflared
    info "Starting cloudflared…"
    if ! timeout 30 systemctl start cloudflared; then
        warn "cloudflared failed to start. Logs:"
        journalctl -u cloudflared -n 15 --no-pager 2>/dev/null || true
        err "cloudflared did not start.\n  If you see a DNS error, your DNS may not have applied yet.\n  Try: echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf && sudo systemctl start cloudflared"
    fi
    assert_service cloudflared
    log "Cloudflare Tunnel installed and running"
fi

# ─────────────────────────────────────────────────────────────────────────────
if [[ -n "$CF_API_TOKEN" && -n "$DOMAIN" ]]; then
step "Cloudflare DNS & Tunnel Route"
# ─────────────────────────────────────────────────────────────────────────────

info "Decoding tunnel token…"
TOKEN_JSON=$(python3 - <<PYEOF
import sys, base64, json
t = "${CLOUDFLARE_TOKEN}".strip()
# Add padding
t += "=" * (4 - len(t) % 4)
print(base64.b64decode(t).decode("utf-8"))
PYEOF
) || err "Failed to decode tunnel token — make sure CF_TOKEN is correct."

TUNNEL_ID=$(echo "$TOKEN_JSON" | cf_json "print(d['t'])") \
    || err "Could not extract tunnel ID from token."
ACCOUNT_ID=$(echo "$TOKEN_JSON" | cf_json "print(d['a'])") \
    || err "Could not extract account ID from token."
log "Tunnel ID: $TUNNEL_ID"

info "Looking up Cloudflare zone for ${DOMAIN}…"
ZONE_RESP=$(cf_api GET "/zones?name=${DOMAIN}")
ZONE_ID=$(echo "$ZONE_RESP" | cf_json "r=d.get('result',[]); print(r[0]['id'] if r else '')")
[[ -z "$ZONE_ID" ]] && err \
    "Zone not found for '${DOMAIN}'.\n  Make sure the domain is added to Cloudflare and nameservers have propagated.\n  Also verify CF_API_TOKEN has Zone:DNS:Edit permission."
log "Zone found: $ZONE_ID"

info "Creating DNS record (www → tunnel)…"
TUNNEL_TARGET="${TUNNEL_ID}.cfargotunnel.com"
dns_upsert "$ZONE_ID" "www.${DOMAIN}" "$TUNNEL_TARGET"
log "DNS: www.${DOMAIN} → ${TUNNEL_TARGET} (proxied)"

info "Configuring tunnel public hostname → localhost:80…"
INGRESS=$(cf_api PUT \
    "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
    "{\"config\":{\"ingress\":[
        {\"hostname\":\"www.${DOMAIN}\",\"service\":\"http://localhost:80\"},
        {\"service\":\"http_status:404\"}
    ]}}")
CF_OK=$(echo "$INGRESS" | cf_json "print(d.get('success', False))")
[[ "$CF_OK" != "True" ]] && err \
    "Failed to configure tunnel ingress.\n  $(echo "$INGRESS" | cf_json "print(d.get('errors','unknown error'))")\n  Check that CF_API_TOKEN has Cloudflare Tunnel:Edit permission."
log "Tunnel route: www.${DOMAIN} → http://localhost:80"

fi  # end CF_API_TOKEN block

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
if [[ -n "$DOMAIN" ]]; then
echo -e "  ${BOLD}Site:${NC}  https://${DOMAIN}"
else
echo -e "  ${BOLD}Site:${NC}  Configure a Public Hostname in Cloudflare Zero Trust:"
echo    "         dash.cloudflare.com → Zero Trust → Networks → Tunnels"
echo    "         Public Hostname → http://localhost:80"
fi
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

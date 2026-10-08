#!/usr/bin/env bash
# Read-only health check for an rpi_website install.
# Usage: sudo bash diagnose.sh [--no-color] [--api]
#   --api   also verify CF_API_TOKEN (read from the environment) with Cloudflare
# Output is safe to paste: tokens and config.env contents are never printed.

# No `set -e`: one failed check must never stop the remaining checks.
set -u
export LC_ALL=C

USE_COLOR=1
CHECK_API=0
for a in "$@"; do
    case $a in
        --no-color) USE_COLOR=0 ;;
        --api)      CHECK_API=1 ;;
        -h|--help)  sed -n '2,5p' "$0"; exit 0 ;;
        *) echo "Unknown option: $a" >&2; exit 2 ;;
    esac
done
[[ -t 1 ]] || USE_COLOR=0

if (( USE_COLOR )); then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

INSTALL_DIR="/opt/rpi-webhost"
WEB_ROOT="/var/www/html"
N_PASS=0; N_WARN=0; N_FAIL=0
FAILED_TUNNEL=0; FAILED_ORIGIN=0

pass()  { N_PASS=$((N_PASS + 1)); printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$1"; }
warn()  { N_WARN=$((N_WARN + 1)); printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1"; [[ -n "${2:-}" ]] && printf '       → %s\n' "$2"; return 0; }
fail()  { N_FAIL=$((N_FAIL + 1)); printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$1"; [[ -n "${2:-}" ]] && printf '       → %s\n' "$2"; return 0; }
note()  { printf '       %s\n' "$1"; }
section() { printf '\n%s── %s ──%s\n' "$BOLD" "$1" "$NC"; }
have()  { command -v "$1" >/dev/null 2>&1; }
t()     { timeout "${T:-8}" "$@"; }   # every external command gets a timeout

SUDO=''
if [[ $EUID -ne 0 ]]; then
    if have sudo && sudo -n true 2>/dev/null; then SUDO='sudo -n'; else
        printf '%sNot running as root — some checks (journal, ufw, sshd -T) will be skipped. Re-run with sudo.%s\n' "$YELLOW" "$NC"
    fi
fi

# ── System ────────────────────────────────────────────────────────────────────
section "System"
ARCH=$(uname -m)
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown")
CODENAME=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-unknown}")
note "Model: $MODEL"
note "OS: $CODENAME   Arch: $ARCH   Kernel: $(uname -r)   Python: $(python3 --version 2>&1)"

case $CODENAME in
    bullseye|bookworm) pass "OS release '$CODENAME' is one the installer was written for" ;;
    *) warn "OS release '$CODENAME' is newer/unknown to install.sh" "DNS, ssh reload and iptables-legacy steps assume Bullseye/Bookworm" ;;
esac

avail_kb=$(df -Pk / | awk 'NR==2{print $4}')
if [[ -n "$avail_kb" && "$avail_kb" -lt 200000 ]]; then fail "Root filesystem nearly full ($((avail_kb/1024)) MB free)"; else pass "Disk space OK ($((avail_kb/1024)) MB free)"; fi

if have vcgencmd; then
    thr=$(t vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    if [[ "$thr" == "0x0" || -z "$thr" ]]; then pass "No power/thermal throttling"; else warn "Throttling flags: $thr" "Under-voltage or overheating; use a better PSU/cable"; fi
fi

if have timedatectl; then
    if [[ "$(t timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
        pass "Clock is NTP-synchronised"
    else
        fail "Clock is not NTP-synchronised ($(date -u))" "A wrong clock breaks TLS to Cloudflare. Check NTP (udp 123) is not blocked"; FAILED_TUNNEL=1
    fi
fi

failed_units=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
if [[ -z "${failed_units// }" ]]; then pass "No failed systemd units"; else warn "Failed units: $failed_units"; fi

# ── Cloudflare tunnel ─────────────────────────────────────────────────────────
section "Cloudflare tunnel"
if ! have cloudflared; then
    fail "cloudflared is not installed" "Re-run install.sh"; FAILED_TUNNEL=1
else
    ver_out=$(t cloudflared --version 2>&1); ver_rc=$?
    if (( ver_rc != 0 )); then
        fail "cloudflared binary does not run (exit $ver_rc): $(echo "$ver_out" | head -1)" \
             "'Illegal instruction' on a Pi Zero 1 (armv6l) means the latest build no longer supports your CPU"
        FAILED_TUNNEL=1
    else
        pass "cloudflared runs: $(echo "$ver_out" | head -1)"
        installed=$(echo "$ver_out" | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1)
        latest=$(T=10 t curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+')
        if [[ -z "$latest" ]]; then warn "Could not look up latest cloudflared release (GitHub unreachable or rate-limited)"
        elif [[ "$installed" == "$latest" ]]; then pass "cloudflared is up to date ($latest)"
        else warn "cloudflared $installed is not the latest ($latest)" "Cloudflare drops support for old versions; the weekly 'cloudflared update' cron may be failing silently"; fi
    fi
fi

if systemctl is-active cloudflared >/dev/null 2>&1; then
    pass "cloudflared service is active"
else
    fail "cloudflared service is not active ($(systemctl is-active cloudflared 2>&1))" "This is the usual cause of Cloudflare error 1033 / 530"; FAILED_TUNNEL=1
fi
systemctl is-enabled cloudflared >/dev/null 2>&1 || warn "cloudflared is not enabled at boot"

if have journalctl; then
    jlog=$($SUDO journalctl -u cloudflared -n 80 --no-pager 2>/dev/null)
    if [[ -z "$jlog" ]]; then
        warn "No cloudflared journal entries readable (need sudo?)"
    else
        if grep -q "Registered tunnel connection" <<<"$jlog"; then
            pass "Journal shows registered tunnel connection(s)"
        else
            fail "No 'Registered tunnel connection' in recent cloudflared logs"; FAILED_TUNNEL=1
        fi
        errs=$(grep -iE "error|failed|timeout|unauthorized|illegal|refused|certificate" <<<"$jlog" | tail -5)
        if [[ -n "$errs" ]]; then warn "Recent cloudflared errors:"; while IFS= read -r l; do note "${l:0:200}"; done <<<"$errs"; fi
    fi
fi

# ── Network / firewall ────────────────────────────────────────────────────────
section "Network & firewall"
if t getent hosts cloudflare.com >/dev/null 2>&1; then pass "DNS resolution works"; else fail "DNS resolution failed" "install.sh's resolv.conf edit is often overwritten by NetworkManager/dhcpcd"; FAILED_TUNNEL=1; fi
resolvers=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
note "resolv.conf nameservers: ${resolvers:-none}"
grep -q '1.1.1.1' /etc/resolv.conf 2>/dev/null || warn "resolv.conf no longer points at 1.1.1.1" "The installer's DNS setting was reverted (harmless if DNS works)"

if t curl -fsS -o /dev/null https://api.cloudflare.com/cdn-cgi/trace 2>/dev/null; then pass "HTTPS to Cloudflare (443) works"; else fail "Cannot reach Cloudflare over HTTPS" "Firewall, DNS or clock problem"; FAILED_TUNNEL=1; fi

# Tunnel edge: port 7844. TCP can be probed; UDP (QUIC) cannot, so report the rule.
if (exec 3<>/dev/tcp/region1.v2.argotunnel.com/7844) 2>/dev/null; then pass "TCP 7844 to Cloudflare edge reachable"; else warn "TCP 7844 to Cloudflare edge not reachable" "install.sh only allows outbound 7844/udp; if QUIC is filtered the tunnel has no TCP fallback"; fi

if have ufw; then
    ufw_out=$($SUDO ufw status verbose 2>/dev/null)
    if [[ -z "$ufw_out" ]]; then warn "Cannot read ufw status (need sudo?)"
    else
        grep -q "Status: active" <<<"$ufw_out" && pass "ufw is active" || warn "ufw is not active"
        grep -qE '7844/udp.*ALLOW OUT' <<<"$ufw_out" && pass "ufw allows outbound 7844/udp" || fail "ufw has no outbound 7844/udp rule" "Tunnel cannot connect"
        grep -qE '7844/tcp.*ALLOW OUT' <<<"$ufw_out" || warn "ufw has no outbound 7844/tcp rule" "No TCP fallback if QUIC is blocked by the network"
        grep -qE '(^|[^0-9])80(/tcp)?.*ALLOW OUT' <<<"$ufw_out" || warn "ufw blocks outbound port 80" "apt mirrors on http:// will fail, so security updates silently stop"
    fi
fi

if have apt-get; then
    last=$(stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null)
    if [[ -n "$last" ]]; then
        age=$(( ($(date +%s) - last) / 86400 ))
        if (( age > 14 )); then warn "apt has not successfully updated in $age days" "unattended-upgrades is not patching the system"; else pass "apt updated $age day(s) ago"; fi
    else
        warn "No record of a successful apt update"
    fi
fi

# ── Origin (nginx + web root) ─────────────────────────────────────────────────
section "Origin (nginx)"
systemctl is-active nginx >/dev/null 2>&1 && pass "nginx service is active" || { fail "nginx is not active" "Cloudflare will show 502"; FAILED_ORIGIN=1; }
if have nginx; then
    if $SUDO nginx -t >/dev/null 2>&1; then pass "nginx config test passes"; else fail "nginx -t fails" "Run: sudo nginx -t"; FAILED_ORIGIN=1; fi
fi
code=$(t curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:80/ 2>/dev/null)
if [[ "$code" == "200" ]]; then pass "Local request to nginx returns 200"; else fail "Local request to nginx returned '${code:-no response}'" "The origin is broken independently of the tunnel"; FAILED_ORIGIN=1; fi
[[ -f "$WEB_ROOT/index.html" ]] && pass "$WEB_ROOT/index.html exists" || warn "$WEB_ROOT/index.html missing"
public=$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.0\.0\.1|\[::1\]|\[::\]:22$|0\.0\.0\.0:22$|\*:22$)' | grep -vE '^(127|::1)' | tr '\n' ' ')
note "Listening on non-loopback besides ssh: ${public:-none}"

# ── Management GUI ────────────────────────────────────────────────────────────
section "Management GUI"
systemctl is-active rpi-webhost >/dev/null 2>&1 && pass "rpi-webhost service is active" || warn "rpi-webhost service is not active" "Only affects the management GUI, not the public site"
if t curl -fsS http://127.0.0.1:8080/api/status >/dev/null 2>&1; then pass "GUI answers on 127.0.0.1:8080"; else warn "GUI not answering on 127.0.0.1:8080"; fi
fl=$(python3 -c 'import flask, werkzeug; print("Flask", flask.__version__ if hasattr(flask,"__version__") else "?", "Werkzeug", werkzeug.__version__)' 2>&1 | tail -1)
note "$fl"
for f in "$INSTALL_DIR/config.env" "$INSTALL_DIR/secret_key"; do
    [[ -e "$f" ]] && { m=$(stat -c %a "$f"); [[ "$m" == "600" ]] && pass "$f mode 600" || warn "$f has mode $m (expected 600)"; }
done

# ── Security config ───────────────────────────────────────────────────────────
section "Security config"
systemctl is-active fail2ban >/dev/null 2>&1 && pass "fail2ban is active" || warn "fail2ban is not active"
if have sshd && [[ -n "$SUDO$([[ $EUID -eq 0 ]] && echo x)" ]]; then
    eff=$($SUDO sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|maxauthtries|x11forwarding) ' | tr '\n' ';')
    note "sshd effective: ${eff:-unreadable}"
    grep -q 'permitrootlogin no' <<<"$eff" && pass "Root SSH login disabled" || warn "Root SSH login is not disabled" "A sshd_config.d drop-in may override install.sh's edit"
fi
if [[ -f /etc/sudoers.d/rpi-webhost ]]; then $SUDO visudo -cf /etc/sudoers.d/rpi-webhost >/dev/null 2>&1 && pass "sudoers.d/rpi-webhost is valid" || fail "sudoers.d/rpi-webhost is invalid"; fi

# ── Public site & API ─────────────────────────────────────────────────────────
section "Public site"
DOMAIN=""
[[ -r "$INSTALL_DIR/config.env" ]] && DOMAIN=$(grep -E '^DOMAIN=' "$INSTALL_DIR/config.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
if [[ -z "$DOMAIN" ]]; then
    note "No DOMAIN found in config.env (set one in the GUI or pass DOMAIN=example.com) — skipping public check"
else
    hdrs=$(T=12 t curl -sSI "https://www.${DOMAIN}/" 2>&1)
    pcode=$(head -1 <<<"$hdrs" | awk '{print $2}')
    note "https://www.${DOMAIN}/ → HTTP ${pcode:-no response}   $(grep -i '^cf-ray' <<<"$hdrs" | tr -d '\r')"
    [[ "$pcode" =~ ^2|^3 ]] && pass "Public site responds ($pcode)" || fail "Public site returned '${pcode:-no response}'"
fi

if (( CHECK_API )); then
    if [[ -z "${CF_API_TOKEN:-}" ]]; then warn "--api given but CF_API_TOKEN is not set in the environment"
    elif t curl -fsS -H "Authorization: Bearer ${CF_API_TOKEN}" https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null | grep -q '"status":"active"'; then pass "CF_API_TOKEN is valid and active"
    else fail "CF_API_TOKEN is invalid, expired or lacks permission"; fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"
printf '%s%d passed%s, %s%d warnings%s, %s%d failed%s\n' "$GREEN" "$N_PASS" "$NC" "$YELLOW" "$N_WARN" "$NC" "$RED" "$N_FAIL" "$NC"
if (( FAILED_TUNNEL && !FAILED_ORIGIN )); then
    echo "Likely cause: the TUNNEL (cloudflared). Cloudflare errors 1033 / 530 / 1016 mean it is not connected."
elif (( FAILED_ORIGIN && !FAILED_TUNNEL )); then
    echo "Likely cause: the ORIGIN (nginx). Cloudflare error 502 / 521 / 522 means it is down or refusing connections."
elif (( FAILED_TUNNEL && FAILED_ORIGIN )); then
    echo "Both the tunnel and the origin have problems — fix the origin first, then the tunnel."
elif (( N_FAIL == 0 )); then
    echo "Everything local looks healthy. If Cloudflare still shows errors, check the tunnel's public hostname/ingress in the Zero Trust dashboard (service should be http://localhost:80)."
fi
exit $(( N_FAIL > 0 ))

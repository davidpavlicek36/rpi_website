# rpi_website

Host your own website on a Raspberry Pi with a single command. Traffic routes through a Cloudflare Tunnel — no open router ports, no exposed home IP, SSL included.

> ❗ **For static websites only.** Cloudflare Tunnel routes all traffic through Cloudflare's infrastructure — they can see the full payload of everything transmitted. Do not use this to host anything with databases, user logins, or sensitive information.

> 🛠️ **Hobby project.** This software has not been tested over a long period of time and comes with no guarantees of stability, security, or continued maintenance. Use at your own risk.

---

## Requirements

- A Raspberry Pi Zero (for more models, see the [Compatibility](#compatibility) section)
- Raspberry Pi OS installed and running
- Internet connection on the Pi
- SSH access to the Pi from your laptop (`ssh pi@<ip>`)
- A free [Cloudflare account](https://www.cloudflare.com) with your domain added

---

## How it works

When someone visits your domain, this is what happens step by step:

```
1. Visitor types your domain in their browser
        ↓
2. DNS resolves to Cloudflare (not your home IP)
        ↓
3. Cloudflare handles the HTTPS connection and SSL certificate
        ↓
4. Cloudflare forwards the request through the encrypted tunnel
        ↓
5. cloudflared (running on your Pi) receives it and passes it to nginx
        ↓
6. nginx reads the requested file from /var/www/html and sends it back
        ↓
7. Response travels back through the tunnel → Cloudflare → visitor's browser
```

**What each piece does:**

- **Cloudflare** — acts as the front door. Handles SSL, hides your home IP, provides DDoS protection. Your domain's DNS points here, not at your Pi directly.
- **cloudflared** — a small background process running on the Pi that keeps a permanent outbound connection to Cloudflare. Because it connects *outward*, your router never needs any ports opened. Restarts automatically on boot.
- **nginx** — the web server running on the Pi. Reads your HTML, CSS, and image files from `/var/www/html` and serves them. Also sets security headers on every response.
- **ufw** — the firewall. Blocks all inbound traffic except SSH. Blocks the Pi from reaching other devices on your home network. Allows only what's needed outbound: DNS, HTTPS, and the Cloudflare tunnel.
- **fail2ban** — watches SSH login attempts. Automatically bans any IP that fails too many times, protecting against brute-force attacks.
- **Management GUI** — a small web app running only on the Pi's localhost. Lets you upload files, check status, and view logs. Only reachable through an SSH tunnel from your laptop — never exposed to the internet.

---

## Install

**Step 1** — Get a Cloudflare tunnel token:

1. Go to [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → **Networks → Tunnels → Create a tunnel**
2. Choose **Cloudflared**, give it a name, copy the token shown

**Step 2** — SSH into your Pi, then run:

```bash
git clone https://github.com/davidpavlicek36/rpi_website.git
cd rpi_website
sudo CF_TOKEN=<your-token> bash install.sh
```

The installer takes 2–5 minutes depending on your Pi model and internet speed. It prints next steps when done.

**Step 3** — Point your domain at the tunnel:

In the Cloudflare dashboard → your tunnel → **Public Hostnames** → **Add a public hostname**:
- Domain: your domain
- Service: `HTTP`, URL: `localhost:80`

Cloudflare provisions SSL automatically. Your site is now live at `https://yourdomain.com`.

---

## Manage your site

The management GUI runs on the Pi but is only accessible through an SSH tunnel — it is never reachable from the internet.

**Step 1** — open a tunnel from your laptop:

```bash
ssh -L 8080:localhost:8080 pi@<your-pi-ip>
```

**Step 2** — open your browser:

```
http://localhost:8080
```

### What you can do

| Page | What it does |
|---|---|
| **Dashboard** | nginx + tunnel status, file list |
| **Upload Files** | Drag-and-drop HTML, CSS, images, fonts — individual files or whole folders |
| **Tunnel & Domain** | Check tunnel status, restart it, save your domain for reference |
| **Logs** | Live nginx access and error logs |

---

## Security

The installer applies the following automatically:

- **Cloudflare Tunnel** — no inbound ports open on your router; all web traffic is outbound-initiated
- **LAN isolation** — RFC1918 ranges (`10.x`, `172.16.x`, `192.168.x`) are blocked outbound; a compromised Pi cannot reach other devices on your home network. System DNS is switched to Cloudflare (1.1.1.1) so name resolution still works
- **Least-privilege service** — the management GUI runs as a dedicated `rpi-webhost` system user, not root. It can only restart cloudflared via a narrow sudoers entry
- **CSRF protection** — the GUI rejects POST requests from any origin other than `localhost:8080`
- **Real visitor IPs** — nginx is configured to read `CF-Connecting-IP` from the tunnel so logs and fail2ban see actual IPs, not `127.0.0.1`
- **HSTS** — nginx sends `Strict-Transport-Security` which Cloudflare forwards to browsers
- **fail2ban** — bans IPs after 5 failed SSH attempts in 10 minutes
- **SSH hardening** — root login disabled, `MaxAuthTries 3`, `LoginGraceTime 20`
- **GUI on localhost only** — never bound to a public interface

**Recommended after install** — set up SSH key auth and disable password login:

```bash
# On your laptop
ssh-copy-id pi@<your-pi-ip>

# On the Pi
sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload sshd
```

---

## Compatibility

**Tested on:** Raspberry Pi Zero 1 WH — Raspberry Pi OS Lite 32-bit (Bullseye)

The following models should work but have not been tested. Use the recommended OS to maximise compatibility:

| Model | Recommended OS | Confidence |
|---|---|---|
| Pi Zero 1 / W / WH | Pi OS Lite **32-bit** (Bullseye) | ✅ Tested |
| Pi Zero 2 W | Pi OS Lite **32-bit** (Bullseye) | 🟡 Untested — nearly identical setup |
| Pi 2 / Pi 3 | Pi OS Lite **32-bit** (Bullseye) | 🟡 Untested — should work |
| Pi 4 | Pi OS Lite **32-bit** (Bullseye) | 🟡 Untested — use Bullseye, not Bookworm |
| Pi 5 | Pi OS Lite **64-bit** (Bookworm) | 🔴 Untested — Bookworm only, may need manual fixes |

> Avoid the desktop version of Pi OS — Lite is recommended for any server use. Always flash using [Raspberry Pi Imager](https://www.raspberrypi.com/software/) and enable SSH in the Advanced Settings before writing.

---

## Troubleshooting

**Installer appears frozen at "Enabling firewall"**
This is a known SSH buffering behaviour — the firewall step applies kernel-level rules which takes time on a Pi Zero (up to 2-3 minutes). The installer is running fine in the background, the output is just buffered by the SSH connection and not displayed yet. Wait 1-2 minutes, then press `Ctrl+C`. The buffered output will flush and you will see that all steps completed successfully. Do not re-run the installer.

**SSH connection refused**
SSH is disabled by default on a fresh Pi OS install. Enable it in Raspberry Pi Imager (Advanced Settings → Enable SSH) before flashing, or connect a keyboard and run `sudo systemctl enable --now ssh`.

**Site not loading**
```bash
sudo systemctl status nginx
sudo systemctl status cloudflared
```
Check that the Public Hostname in the Cloudflare dashboard points to `http://localhost:80`.

**Tunnel not connecting**
```bash
sudo journalctl -u cloudflared -n 50
```
Make sure outbound port 443 is not blocked and the token is correct.

**Can't reach the GUI**
Make sure the SSH tunnel is open (`ssh -L 8080:localhost:8080 pi@<ip>`) and visit `http://localhost:8080` — not https.

**GUI service not running**
```bash
sudo systemctl status rpi-webhost
sudo systemctl restart rpi-webhost
```


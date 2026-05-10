# rpi_website

Host your own website on a Raspberry Pi with a single command. Traffic routes through a Cloudflare Tunnel — no open router ports, no exposed home IP, SSL included.

---

## Requirements

- A Raspberry Pi (any model — Zero, 2, 3, 4, 5)
- Raspberry Pi OS installed and running
- Internet connection on the Pi
- SSH access to the Pi from your laptop (`ssh pi@<ip>`)
- A free [Cloudflare account](https://www.cloudflare.com) with your domain added

---

## How it works

```
Visitor → Cloudflare (SSL) → encrypted tunnel → Pi → nginx
```

`cloudflared` runs on the Pi and creates an outbound tunnel to Cloudflare. No ports are forwarded on your router. Your home IP is never exposed to visitors.

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

| Pi model | Works |
|---|---|
| Pi Zero / Zero W (ARMv6) | Yes |
| Pi 2 / Pi 3 (ARMv7) | Yes |
| Pi 4 / Pi 5 (ARM64) | Yes |

---

## Troubleshooting

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

---

## Disclaimer

This software is provided for educational purposes and personal use only. It is intended for hosting **simple static websites** (HTML, CSS, images) with no databases, user logins, or sensitive data.

By using this software you agree that:

- You are solely responsible for what you host and how you configure your system
- The author(s) provide no warranty, guarantee of security, or liability of any kind
- You will comply with Cloudflare's Terms of Service and your internet provider's terms
- You understand the security implications of running a publicly accessible server from a home network

See the [MIT License](LICENSE) for full terms.

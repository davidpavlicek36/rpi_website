# rpi_website

Host your own website on a Raspberry Pi with a single command. No prior Linux knowledge required.

---

## Requirements

- A Raspberry Pi (any model — Zero, 2, 3, 4, 5)
- Raspberry Pi OS installed and running
- Internet connection on the Pi
- SSH access to the Pi from your laptop

---

## Install

SSH into your Pi, then run:

```bash
git clone https://github.com/marshall1405/rpi_website.git
cd rpi_website
sudo bash install.sh
```

The installer will set everything up automatically and print instructions when it finishes. It takes 2–5 minutes depending on your Pi model and internet speed.

---

## Manage your site

The management GUI runs on your Pi but is only accessible through an SSH tunnel — it is never exposed to the internet.

**Step 1** — open a tunnel from your laptop:

```bash
ssh -L 8080:localhost:8080 pi@<your-pi-ip>
```

**Step 2** — open your browser and go to:

```
http://localhost:8080
```

### What you can do

| Page | What it does |
|---|---|
| **Dashboard** | See nginx status, your IP, live file list |
| **Upload Files** | Drag and drop HTML, CSS, images, fonts, etc. |
| **Domain & SSL** | Point a domain to your Pi and get a free HTTPS certificate |
| **Logs** | Watch nginx access and error logs in real time |

---

## Getting your site on the internet

### Option A — you have a domain name

1. Find your Pi's public IP: run `curl -s ifconfig.me` on the Pi
2. In your domain registrar's DNS settings, add an **A record** pointing to that IP
3. Wait for DNS to propagate (usually a few minutes, up to 24 h)
4. Open the GUI → **Domain & SSL**, enter your domain and email, click **Save**
5. Click **Get Free SSL Certificate** — your site will be live at `https://yourdomain.com`

### Option B — no domain, no static IP

Use a free dynamic DNS service to get a stable address:

- [DuckDNS](https://www.duckdns.org) — free subdomain (e.g. `yourname.duckdns.org`)
- [Cloudflare](https://www.cloudflare.com) — free plan with DNS management

Set up dynamic DNS first, then follow Option A using your new subdomain.

---

## Security

The installer automatically:

- Opens only ports 22 (SSH), 80 (HTTP), and 443 (HTTPS) — everything else is blocked
- Enables **fail2ban** to block repeated failed SSH login attempts
- Disables root login over SSH
- Binds the management GUI to `localhost` only (never reachable from the internet)

**Recommended after install** — set up SSH key authentication and disable password login:

```bash
# On your laptop, copy your public key to the Pi
ssh-copy-id pi@<your-pi-ip>

# Then on the Pi, disable password login
sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload sshd
```

---

## Compatibility

| Pi model | Works |
|---|---|
| Pi Zero / Zero W | Yes |
| Pi 2 / Pi 3 | Yes |
| Pi 4 / Pi 5 | Yes |

---

## Troubleshooting

**Site not loading after install**
Run `sudo systemctl status nginx` on the Pi to check if nginx started correctly.

**Can't reach the GUI**
Make sure the SSH tunnel command is running in a terminal on your laptop (`ssh -L 8080:localhost:8080 pi@<ip>`), then open `http://localhost:8080` — not `https`.

**certbot fails**
Port 80 must be reachable from the internet when requesting a certificate. Check that your router forwards port 80 to the Pi's local IP, and that DNS has propagated.

**GUI service not running**
```bash
sudo systemctl status rpi-webhost
sudo systemctl restart rpi-webhost
```

---

## License

MIT

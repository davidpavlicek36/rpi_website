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

The installer sets everything up and prints instructions when it finishes. It takes 2–5 minutes depending on your Pi model and internet speed.

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

### Option A — standard (direct connection)

Your Pi listens on ports 80 and 443. You forward those ports on your router to the Pi.

1. Find your Pi's public IP: run `curl -s ifconfig.me` on the Pi
2. In your router settings, forward ports **80** and **443** to the Pi's local IP
3. In your domain registrar's DNS settings, add an **A record** pointing to that public IP
4. Wait for DNS to propagate (usually a few minutes, up to 24 h)
5. Open the GUI → **Domain & SSL**, enter your domain and email, click **Save**
6. Click **Get Free SSL Certificate** — your site will be live at `https://yourdomain.com`

No domain? Use a free dynamic DNS service like [DuckDNS](https://www.duckdns.org) to get a stable address first.

### Option B — Cloudflare Tunnel (recommended)

No open ports. No port forwarding. Your Pi connects outward to Cloudflare — nobody can connect inward to your home network directly. See the [Cloudflare Tunnel](#cloudflare-tunnel) section below.

---

## Cloudflare Tunnel

Instead of opening ports on your router, `cloudflared` runs on the Pi and creates an outbound encrypted tunnel to Cloudflare's network. All web traffic flows through that tunnel. Your home IP is never exposed.

```
Visitor → Cloudflare → (encrypted tunnel) → Pi → nginx
```

**Pros:**
- No ports open on your router — your home network is not directly reachable
- Your real home IP is completely hidden from visitors
- Free DDoS protection from Cloudflare
- Works even if your ISP blocks inbound ports (common on mobile/4G)
- Works without a static IP
- HTTPS is handled by Cloudflare — no certbot needed

**Cons:**
- Requires a Cloudflare account and a domain managed by Cloudflare
- All traffic passes through Cloudflare's servers (fine for a personal website, worth knowing)
- If Cloudflare has an outage, your site goes down even if your Pi is running fine

### Setup

**1.** Create a free account at [cloudflare.com](https://www.cloudflare.com) and add your domain.

**2.** Go to **Zero Trust → Networks → Connectors → Add a tunnel**.
- Choose **Cloudflared** as the connector type
- Give the tunnel a name (e.g. `my-pi`)
- On the next screen, Cloudflare shows you a token — copy it

**3.** On your Pi, run the installer with the token:

```bash
sudo bash install.sh --cloudflare <YOUR_TOKEN>
```

That's it. Cloudflare will show your tunnel as **Active** in the dashboard. Set the **Public Hostname** in the tunnel settings to your domain and point it at `http://localhost:80`.

### Checking tunnel status

```bash
sudo systemctl status cloudflared
```

---

## Security

The installer automatically:

- **Blocks all inbound traffic** except SSH (and HTTP/HTTPS in standard mode)
- **Blocks all outbound traffic** from the Pi except DNS, HTTPS, and NTP — the Pi cannot reach other devices on your home network even if compromised
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
Make sure the SSH tunnel is open in a terminal on your laptop (`ssh -L 8080:localhost:8080 pi@<ip>`), then open `http://localhost:8080` — not `https`.

**certbot fails**
Port 80 must be reachable from the internet. Check that your router is forwarding port 80 to the Pi and that DNS has propagated.

**Cloudflare tunnel not connecting**
```bash
sudo systemctl status cloudflared
sudo journalctl -u cloudflared -n 50
```
Make sure the token is correct and your Pi has outbound internet access on port 443.

**GUI service not running**
```bash
sudo systemctl status rpi-webhost
sudo systemctl restart rpi-webhost
```

---

## License

MIT

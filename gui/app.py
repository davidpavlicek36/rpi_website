#!/usr/bin/env python3
import os
import re
import subprocess
import time
from pathlib import Path

from flask import (Flask, render_template, request, redirect,
                   url_for, flash, Response, jsonify, stream_with_context)
from werkzeug.utils import secure_filename

app = Flask(__name__)
app.secret_key = os.urandom(32)

INSTALL_DIR  = Path('/opt/rpi-webhost')
WEB_ROOT     = Path('/var/www/html')
NGINX_CONF   = Path('/etc/nginx/sites-available/rpi-webhost')
NGINX_LINK   = Path('/etc/nginx/sites-enabled/rpi-webhost')
CONFIG_FILE  = INSTALL_DIR / 'config.env'

ALLOWED_EXT = {
    'html', 'htm', 'css', 'js', 'json', 'xml', 'txt',
    'png', 'jpg', 'jpeg', 'gif', 'svg', 'ico', 'webp',
    'woff', 'woff2', 'ttf', 'eot', 'otf',
    'mp4', 'webm', 'mp3', 'ogg',
    'pdf',
}

# ── Helpers ──────────────────────────────────────────────────────────────────

def allowed(filename: str) -> bool:
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXT

def valid_domain(d: str) -> bool:
    return bool(re.fullmatch(
        r'[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+', d
    ))

def valid_email(e: str) -> bool:
    return bool(re.fullmatch(
        r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}', e
    ))

def load_config() -> dict:
    cfg = {}
    if CONFIG_FILE.exists():
        for line in CONFIG_FILE.read_text().splitlines():
            if '=' in line and not line.startswith('#'):
                k, _, v = line.partition('=')
                cfg[k.strip()] = v.strip()
    return cfg

def save_config(cfg: dict):
    CONFIG_FILE.write_text('\n'.join(f"{k}={v}" for k, v in cfg.items()) + '\n')
    CONFIG_FILE.chmod(0o600)

def nginx_status() -> str:
    try:
        r = subprocess.run(['systemctl', 'is-active', 'nginx'],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except Exception:
        return 'unknown'

def get_local_ip() -> str:
    try:
        r = subprocess.run(['hostname', '-I'], capture_output=True, text=True, timeout=5)
        return r.stdout.strip().split()[0]
    except Exception:
        return 'unknown'

def reload_nginx():
    subprocess.run(['nginx', '-t'], capture_output=True, check=True)
    subprocess.run(['systemctl', 'reload', 'nginx'], capture_output=True, check=True)

def write_nginx_http(domain: str):
    conf = f"""server {{
    listen 80;
    listen [::]:80;
    server_name {domain};
    root /var/www/html;
    index index.html index.htm;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    location / {{
        try_files $uri $uri/ =404;
    }}

    location ~* \\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|woff|woff2)$ {{
        expires 30d;
        add_header Cache-Control "public, immutable";
    }}
}}
"""
    NGINX_CONF.write_text(conf)
    if not NGINX_LINK.exists():
        NGINX_LINK.symlink_to(NGINX_CONF)

def list_web_files() -> list:
    if not WEB_ROOT.exists():
        return []
    files = []
    for f in sorted(WEB_ROOT.rglob('*')):
        if f.is_file():
            rel = str(f.relative_to(WEB_ROOT))
            size = f.stat().st_size
            files.append({'path': rel, 'size': size})
    return files

# ── Routes ───────────────────────────────────────────────────────────────────

@app.route('/')
def index():
    cfg = load_config()
    return render_template('index.html',
                           nginx=nginx_status(),
                           ip=get_local_ip(),
                           domain=cfg.get('DOMAIN', ''),
                           ssl=cfg.get('SSL', 'no'),
                           files=list_web_files())


@app.route('/upload', methods=['GET', 'POST'])
def upload():
    if request.method == 'POST':
        files   = request.files.getlist('files')
        subdir  = request.form.get('subdir', '').strip().strip('/')

        # Validate subdir: only alphanumeric, hyphens, underscores, slashes
        if subdir and not re.fullmatch(r'[a-zA-Z0-9/_\-]+', subdir):
            flash('Invalid subdirectory name.', 'error')
            return redirect(url_for('upload'))

        uploaded, errors = [], []
        for f in files:
            if not f.filename:
                continue
            name = secure_filename(f.filename)
            if not name:
                errors.append(f'Skipped: empty filename')
                continue
            if not allowed(name):
                errors.append(f'Skipped {name}: file type not allowed')
                continue

            dest_dir = WEB_ROOT / subdir if subdir else WEB_ROOT
            dest_dir.mkdir(parents=True, exist_ok=True)
            dest = dest_dir / name
            f.save(str(dest))
            dest.chmod(0o644)
            uploaded.append(f"{subdir + '/' if subdir else ''}{name}")

        if uploaded:
            flash(f"Uploaded: {', '.join(uploaded)}", 'success')
        for e in errors:
            flash(e, 'error')
        return redirect(url_for('upload'))

    return render_template('upload.html', files=list_web_files())


@app.route('/upload/delete', methods=['POST'])
def delete_file():
    rel = request.form.get('path', '')
    # Sanitize: prevent path traversal
    try:
        target = (WEB_ROOT / rel).resolve()
        target.relative_to(WEB_ROOT.resolve())  # raises if outside web root
    except (ValueError, Exception):
        flash('Invalid path.', 'error')
        return redirect(url_for('upload'))

    if target.exists() and target.is_file():
        target.unlink()
        flash(f'Deleted {rel}', 'success')
    return redirect(url_for('upload'))


@app.route('/domain', methods=['GET', 'POST'])
def domain():
    cfg = load_config()
    if request.method == 'POST':
        action = request.form.get('action', '')

        if action == 'save':
            new_domain = request.form.get('domain', '').strip().lower()
            new_email  = request.form.get('email', '').strip()

            if not valid_domain(new_domain):
                flash('Invalid domain name.', 'error')
                return redirect(url_for('domain'))
            if not valid_email(new_email):
                flash('Invalid email address.', 'error')
                return redirect(url_for('domain'))

            cfg['DOMAIN'] = new_domain
            cfg['EMAIL']  = new_email
            save_config(cfg)

            try:
                write_nginx_http(new_domain)
                reload_nginx()
                flash(f'Domain set to {new_domain}. nginx reloaded.', 'success')
            except subprocess.CalledProcessError as e:
                flash(f'nginx config error: {e}', 'error')

        elif action == 'certbot':
            dom   = cfg.get('DOMAIN', '')
            email = cfg.get('EMAIL', '')
            if not dom or not email:
                flash('Save your domain and email first.', 'error')
                return redirect(url_for('domain'))
            try:
                result = subprocess.run(
                    ['certbot', '--nginx',
                     '-d', dom,
                     '--email', email,
                     '--agree-tos',
                     '--non-interactive',
                     '--redirect'],
                    capture_output=True, text=True, timeout=120
                )
                if result.returncode == 0:
                    cfg['SSL'] = 'yes'
                    save_config(cfg)
                    flash('SSL certificate obtained! Your site now uses HTTPS.', 'success')
                else:
                    flash(f'certbot error: {result.stderr[-800:]}', 'error')
            except subprocess.TimeoutExpired:
                flash('certbot timed out (120 s). Check that port 80 is reachable from the internet.', 'error')

        return redirect(url_for('domain'))

    return render_template('domain.html', cfg=cfg)


@app.route('/logs')
def logs():
    return render_template('logs.html')


@app.route('/api/logs')
def api_logs():
    log_type = request.args.get('type', 'access')
    if log_type not in ('access', 'error'):
        log_type = 'access'
    path = f'/var/log/nginx/{log_type}.log'

    def generate():
        try:
            proc = subprocess.Popen(
                ['tail', '-n', '80', '-f', path],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
            for line in proc.stdout:
                yield f'data: {line.rstrip()}\n\n'
                time.sleep(0)   # yield to event loop
        except Exception as exc:
            yield f'data: [error: {exc}]\n\n'

    return Response(
        stream_with_context(generate()),
        mimetype='text/event-stream',
        headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'}
    )


@app.route('/api/status')
def api_status():
    return jsonify({'nginx': nginx_status(), 'ip': get_local_ip()})


if __name__ == '__main__':
    app.run(host='127.0.0.1', port=8080, debug=False, threaded=True)

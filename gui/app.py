#!/usr/bin/env python3
import os
import re
import subprocess
import time
from pathlib import Path
from urllib.parse import urlparse

from flask import (Flask, render_template, request, redirect,
                   url_for, flash, Response, jsonify, stream_with_context)
from werkzeug.utils import secure_filename

app = Flask(__name__)

INSTALL_DIR  = Path('/opt/rpi-webhost')
WEB_ROOT     = Path('/var/www/html')
NGINX_CONF   = Path('/etc/nginx/sites-available/rpi-webhost')
NGINX_LINK   = Path('/etc/nginx/sites-enabled/rpi-webhost')
CONFIG_FILE  = INSTALL_DIR / 'config.env'
SECRET_FILE  = INSTALL_DIR / 'secret_key'

ALLOWED_EXT = {
    'html', 'htm', 'css', 'js', 'json', 'xml', 'txt',
    'png', 'jpg', 'jpeg', 'gif', 'svg', 'ico', 'webp',
    'woff', 'woff2', 'ttf', 'eot', 'otf',
    'mp4', 'webm', 'mp3', 'ogg',
    'pdf',
}

# ── Secret key — persistent across restarts ───────────────────────────────────
def _load_secret_key() -> bytes:
    try:
        if SECRET_FILE.exists():
            return SECRET_FILE.read_bytes().strip()
        if SECRET_FILE.parent.exists():
            key = os.urandom(32).hex().encode()
            SECRET_FILE.write_bytes(key + b'\n')
            SECRET_FILE.chmod(0o600)
            return key
    except OSError:
        pass
    return os.urandom(32)

app.secret_key = _load_secret_key()
app.config['MAX_CONTENT_LENGTH'] = 50 * 1024 * 1024  # 50 MB upload cap

# ── CSRF protection — reject cross-origin POSTs ───────────────────────────────
@app.before_request
def csrf_protect():
    if request.method != 'POST':
        return
    origin  = request.headers.get('Origin', '')
    referer = request.headers.get('Referer', '')
    # Require at least one source header — reject silent requests entirely
    check = origin or referer
    if not check:
        return 'Forbidden', 403
    # Exact netloc comparison prevents startswith bypass (e.g. localhost:8080.evil.com)
    parsed = urlparse(check)
    if parsed.scheme != 'http' or parsed.netloc != request.host:
        return 'Forbidden', 403

# ── Helpers ───────────────────────────────────────────────────────────────────

def allowed(filename: str) -> bool:
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXT

def valid_domain(d: str) -> bool:
    return bool(re.fullmatch(
        r'[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+', d
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

def cloudflared_status() -> str:
    try:
        r = subprocess.run(['systemctl', 'is-active', 'cloudflared'],
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

# ── Routes ────────────────────────────────────────────────────────────────────

@app.route('/')
def index():
    cfg = load_config()
    return render_template('index.html',
                           nginx=nginx_status(),
                           cloudflared=cloudflared_status(),
                           ip=get_local_ip(),
                           domain=cfg.get('DOMAIN', ''),
                           files=list_web_files())


@app.route('/upload', methods=['GET', 'POST'])
def upload():
    if request.method == 'POST':
        files     = request.files.getlist('files')
        filepaths = request.form.getlist('filepaths')
        subdir    = request.form.get('subdir', '').strip().strip('/')

        if subdir and not re.fullmatch(r'[a-zA-Z0-9/_\-]+', subdir):
            flash('Invalid subdirectory name.', 'error')
            return redirect(url_for('upload'))

        uploaded, errors = [], []
        for i, f in enumerate(files):
            if not f.filename:
                continue

            if filepaths and i < len(filepaths):
                rel = filepaths[i]
                parts = Path(rel).parts
                inner = Path(*parts[1:]) if len(parts) > 1 else Path(parts[0])
                safe_parts = [secure_filename(p) for p in inner.parts]
                if not all(safe_parts):
                    errors.append(f'Skipped: unsafe path {rel}')
                    continue
                rel_path = Path(*safe_parts)
            else:
                name = secure_filename(f.filename)
                if not name:
                    errors.append('Skipped: empty filename')
                    continue
                rel_path = Path(name)

            if not allowed(rel_path.name):
                errors.append(f'Skipped {rel_path}: file type not allowed')
                continue

            base = WEB_ROOT / subdir if subdir else WEB_ROOT
            dest = (base / rel_path).resolve()

            try:
                dest.relative_to(WEB_ROOT.resolve())
            except ValueError:
                errors.append(f'Skipped {rel_path}: path outside web root')
                continue

            dest.parent.mkdir(parents=True, exist_ok=True)
            f.save(str(dest))
            dest.chmod(0o644)
            uploaded.append(str(rel_path))

        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            return jsonify({'uploaded': uploaded, 'errors': errors})

        if uploaded:
            flash(f"Uploaded {len(uploaded)} file(s): {', '.join(uploaded[:5])}{'…' if len(uploaded) > 5 else ''}", 'success')
        for e in errors:
            flash(e, 'error')
        return redirect(url_for('upload'))

    return render_template('upload.html', files=list_web_files())


@app.route('/upload/delete', methods=['POST'])
def delete_file():
    rel = request.form.get('path', '')
    try:
        target = (WEB_ROOT / rel).resolve()
        target.relative_to(WEB_ROOT.resolve())
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

        if action == 'save_domain':
            new_domain = request.form.get('domain', '').strip().lower()
            if not valid_domain(new_domain):
                flash('Invalid domain name.', 'error')
                return redirect(url_for('domain'))
            cfg['DOMAIN'] = new_domain
            save_config(cfg)
            flash(f'Domain saved: {new_domain}', 'success')

        elif action == 'restart_tunnel':
            try:
                subprocess.run(
                    ['sudo', '/usr/bin/systemctl', 'restart', 'cloudflared'],
                    capture_output=True, check=True, timeout=15
                )
                flash('Cloudflare Tunnel restarted.', 'success')
            except subprocess.CalledProcessError as e:
                flash(f'Failed to restart tunnel: {e.stderr}', 'error')
            except subprocess.TimeoutExpired:
                flash('Restart timed out — check the Pi directly.', 'error')

        return redirect(url_for('domain'))

    return render_template('domain.html', cfg=cfg, tunnel=cloudflared_status())


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
        proc = None
        try:
            proc = subprocess.Popen(
                ['sudo', '/usr/bin/tail', '-n', '80', '-f', path],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
            for line in proc.stdout:
                yield f'data: {line.rstrip()}\n\n'
                time.sleep(0)
        except Exception as exc:
            yield f'data: [error: {exc}]\n\n'
        finally:
            if proc and proc.poll() is None:
                proc.terminate()

    return Response(
        stream_with_context(generate()),
        mimetype='text/event-stream',
        headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'}
    )


@app.route('/api/status')
def api_status():
    return jsonify({'nginx': nginx_status(), 'cloudflared': cloudflared_status(), 'ip': get_local_ip()})


if __name__ == '__main__':
    app.run(host='127.0.0.1', port=8080, debug=False, threaded=True)

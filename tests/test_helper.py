import json
import os
import stat
import threading
from types import SimpleNamespace
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

import pytest

from conftest import make_token


# ── parse_token ───────────────────────────────────────────────────────────────

def test_parse_token_valid(helper, token):
    tok, data = helper.parse_token(token)
    assert tok == token and data['t'].startswith('1111')


def test_parse_token_length_multiple_of_four_is_not_over_padded(helper):
    # 'x'-padded JSON whose base64 length is already a multiple of 4
    for n in range(0, 4):
        tok = make_token(s='c2VjcmV0' + 'A' * n)
        if len(tok) % 4 == 0:
            assert helper.parse_token(tok)[1]['s']
            return
    pytest.fail('no aligned token produced')


def test_parse_token_accepts_pasted_install_command(helper, token):
    assert helper.parse_token('sudo cloudflared service install ' + token)[0] == token


@pytest.mark.parametrize('bad', ['', '   ', 'not-a-token!!', 'aGVsbG8=', make_token(t='../etc')])
def test_parse_token_rejects_garbage(helper, bad):
    with pytest.raises(helper.Fail):
        helper.parse_token(bad)


# ── Cloudflare API stub ───────────────────────────────────────────────────────

class Stub(BaseHTTPRequestHandler):
    calls = []
    fail_zone = False
    ingress = [{'hostname': 'blog.example.com', 'service': 'http://localhost:9000'},
               {'service': 'http_status:404'}]

    def log_message(self, *a):
        pass

    def _send(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return json.loads(self.rfile.read(n)) if n else None

    def _handle(self):
        path = urlparse(self.path)
        body = self._body()
        Stub.calls.append((self.command, path.path, path.query, body, self.headers.get('Authorization')))
        if path.path == '/zones':
            if Stub.fail_zone:
                return self._send({'success': False, 'errors': [{'message': 'Authentication error'}]}, 403)
            return self._send({'success': True, 'result': [{'id': 'zone1'}]})
        if path.path.endswith('/dns_records') and self.command == 'GET':
            return self._send({'success': True, 'result': []})
        if path.path.endswith('/dns_records') and self.command == 'POST':
            return self._send({'success': True, 'result': {'id': 'rec1'}})
        if path.path.endswith('/configurations'):
            if self.command == 'GET':
                return self._send({'success': True, 'result': {'config': {'ingress': Stub.ingress, 'warp-routing': {'enabled': False}}}})
            return self._send({'success': True, 'result': {}})
        self._send({'success': False, 'errors': [{'message': 'unexpected ' + path.path}]}, 404)

    do_GET = do_POST = do_PUT = do_PATCH = _handle


@pytest.fixture
def cf_stub(helper, monkeypatch, tmp_path, token):
    Stub.calls = []
    Stub.fail_zone = False
    server = HTTPServer(('127.0.0.1', 0), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    unit = tmp_path / 'cloudflared.service'
    unit.write_text('[Service]\nExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token %s\n' % token)
    monkeypatch.setattr(helper, 'CF_API', 'http://127.0.0.1:%d' % server.server_port)
    monkeypatch.setattr(helper, 'UNIT_FILE', unit)
    monkeypatch.setattr(helper, 'TOKEN_FILE', tmp_path / 'no-env-file')
    monkeypatch.setattr(helper, 'CONFIG_FILE', tmp_path / 'config.env')
    monkeypatch.setattr(helper, 'audit', lambda m: None)
    yield Stub
    server.shutdown()


def run_set_domain(helper, monkeypatch, api_token, domain='example.com'):
    import io
    monkeypatch.setattr('sys.stdin', io.StringIO(api_token + '\n'))
    helper.cmd_set_domain(domain)


def test_set_domain_creates_dns_keeps_other_hostnames_and_saves(helper, cf_stub, monkeypatch, tmp_path, capsys):
    run_set_domain(helper, monkeypatch, 'API-SECRET')
    out = capsys.readouterr().out
    assert 'www.example.com' in out and 'API-SECRET' not in out

    post = next(c for c in cf_stub.calls if c[0] == 'POST')
    assert post[3]['content'] == '11111111-2222-3333-4444-555555555555.cfargotunnel.com'
    assert post[3]['name'] == 'www.example.com' and post[3]['proxied'] is True

    put = next(c for c in cf_stub.calls if c[0] == 'PUT')
    hostnames = [r.get('hostname') for r in put[3]['config']['ingress']]
    assert hostnames == ['blog.example.com', 'www.example.com', None]   # others kept, catch-all last
    assert put[3]['config']['warp-routing'] == {'enabled': False}       # unrelated config kept
    assert all(c[4] == 'Bearer API-SECRET' for c in cf_stub.calls)

    assert 'DOMAIN=example.com' in (tmp_path / 'config.env').read_text()


def test_set_domain_api_error_is_reported_without_secret(helper, cf_stub, monkeypatch):
    cf_stub.fail_zone = True
    with pytest.raises(helper.Fail) as e:
        run_set_domain(helper, monkeypatch, 'API-SECRET')
    assert 'Authentication error' in str(e.value) and 'API-SECRET' not in str(e.value)


@pytest.mark.parametrize('domain', ['nodot', 'a b.com', 'x.com; rm -rf /', '../x.com', 'x.c'])
def test_set_domain_rejects_bad_domains(helper, cf_stub, monkeypatch, domain):
    with pytest.raises(helper.Fail):
        run_set_domain(helper, monkeypatch, 'API-SECRET', domain)
    assert cf_stub.calls == []


def test_save_domain_replaces_existing_line(helper, monkeypatch, tmp_path):
    cfg = tmp_path / 'config.env'
    cfg.write_text('FOO=1\nDOMAIN=old.com\n')
    monkeypatch.setattr(helper, 'CONFIG_FILE', cfg)
    helper.save_domain('new.com')
    assert cfg.read_text() == 'FOO=1\nDOMAIN=new.com\n'


def test_main_rejects_unknown_or_extra_args(helper):
    for argv in (['x'], ['x', 'set-token', 'extra'], ['x', 'set-domain'], ['x', 'set-domain', 'a.com', 'b.com'], ['x', 'rm']):
        with pytest.raises(helper.Fail):
            helper.main(argv)


# ── set-token with fake system commands ──────────────────────────────────────

@pytest.fixture
def shims(helper, monkeypatch, tmp_path):
    unit = tmp_path / 'cloudflared.service'
    envf = tmp_path / 'etc' / 'tunnel.env'
    unit.write_text('OLD-UNIT\n')
    bindir = tmp_path / 'bin'
    bindir.mkdir()
    log = tmp_path / 'calls.log'

    def shim(name, body):
        p = bindir / name
        p.write_text('#!/bin/sh\necho "%s $*" >> %s\n%s\n' % (name, log, body))
        p.chmod(p.stat().st_mode | stat.S_IEXEC)

    shim('systemctl', 'exit 0')
    shim('cloudflared', 'exit 0')
    shim('journalctl', '[ -n "$CONNECT" ] && echo "INF Registered tunnel connection"; exit 0')
    monkeypatch.setenv('PATH', '%s:%s' % (bindir, os.environ['PATH']))
    monkeypatch.setattr(helper, 'UNIT_FILE', unit)
    monkeypatch.setattr(helper, 'TOKEN_FILE', envf)
    monkeypatch.setattr(helper, 'CONNECT_TIMEOUT', 1)
    audits = []
    monkeypatch.setattr(helper, 'audit', audits.append)
    return SimpleNamespace(unit=unit, env=envf, log=log, audits=audits)


def feed(monkeypatch, text):
    import io
    monkeypatch.setattr('sys.stdin', io.StringIO(text))


def test_set_token_success_keeps_token_out_of_unit_and_args(helper, shims, monkeypatch, token, capsys):
    monkeypatch.setenv('CONNECT', '1')
    feed(monkeypatch, token + '\n')
    helper.cmd_set_token()
    assert 'connected' in capsys.readouterr().out
    assert shims.env.read_text() == 'TUNNEL_TOKEN=%s\n' % token
    assert stat.S_IMODE(shims.env.stat().st_mode) == 0o600           # root-only
    unit = shims.unit.read_text()
    assert token not in unit and '--token' not in unit               # not visible in ps / world-readable unit
    assert 'EnvironmentFile=%s' % shims.env in unit and 'tunnel run' in unit
    assert token not in shims.log.read_text()                        # never passed to any command as an argument
    assert shims.audits == ['tunnel token changed (tunnel 11111111-2222-3333-4444-555555555555)']


def test_set_token_rolls_back_when_tunnel_never_connects(helper, shims, monkeypatch, token):
    shims.env.parent.mkdir()
    shims.env.write_text('TUNNEL_TOKEN=OLD\n')
    feed(monkeypatch, token + '\n')
    with pytest.raises(helper.Fail) as e:
        helper.cmd_set_token()
    assert 'restored' in str(e.value) and token not in str(e.value)
    assert shims.unit.read_text() == 'OLD-UNIT\n'
    assert shims.env.read_text() == 'TUNNEL_TOKEN=OLD\n'
    assert 'FAILED' in shims.audits[0] and token not in shims.audits[0]


def test_set_token_without_cloudflared_changes_nothing(helper, shims, monkeypatch, token):
    monkeypatch.setenv('PATH', '/nonexistent')
    feed(monkeypatch, token + '\n')
    with pytest.raises(helper.Fail):
        helper.cmd_set_token()
    assert shims.unit.read_text() == 'OLD-UNIT\n' and not shims.env.exists()


def test_set_token_invalid_token_changes_nothing(helper, shims, monkeypatch):
    feed(monkeypatch, 'garbage\n')
    with pytest.raises(helper.Fail):
        helper.cmd_set_token()
    assert shims.unit.read_text() == 'OLD-UNIT\n' and not shims.log.exists()


def test_current_token_reads_env_file_then_legacy_unit(helper, shims, token):
    shims.unit.write_text('ExecStart=/x tunnel run --token %s\n' % token)
    assert helper.current_token()['t'].startswith('1111')           # legacy install
    shims.unit.write_text('OLD-UNIT\n')
    shims.env.parent.mkdir()
    shims.env.write_text('TUNNEL_TOKEN=%s\n' % token)
    assert helper.current_token()['t'].startswith('1111')           # new layout


def test_harden_token_moves_legacy_token_out_of_the_unit(helper, shims, monkeypatch, token, capsys):
    monkeypatch.setenv('CONNECT', '1')
    shims.unit.write_text('ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token %s\n' % token)
    helper.cmd_harden_token()
    assert token not in shims.unit.read_text() and shims.env.read_text() == 'TUNNEL_TOKEN=%s\n' % token
    capsys.readouterr()
    helper.cmd_harden_token()                                       # idempotent
    assert 'already' in capsys.readouterr().out


# ── config.env is in a directory the GUI user controls: never follow links ────

def test_save_domain_refuses_symlinked_config(helper, monkeypatch, tmp_path):
    victim = tmp_path / 'victim'
    victim.write_text('precious\n')
    cfg = tmp_path / 'config.env'
    cfg.symlink_to(victim)
    monkeypatch.setattr(helper, 'CONFIG_FILE', cfg)
    with pytest.raises(helper.Fail):
        helper.save_domain('example.com')
    assert victim.read_text() == 'precious\n'


def test_save_domain_refuses_hardlinked_config_and_leaves_target_alone(helper, monkeypatch, tmp_path):
    victim = tmp_path / 'victim'
    victim.write_text('precious\n')
    cfg = tmp_path / 'config.env'
    os.link(victim, cfg)
    monkeypatch.setattr(helper, 'CONFIG_FILE', cfg)
    with pytest.raises(helper.Fail):
        helper.save_domain('example.com')
    assert victim.read_text() == 'precious\n'


def test_status_does_not_follow_symlinked_config(helper, monkeypatch, tmp_path, capsys):
    secret = tmp_path / 'secret'
    secret.write_text('DOMAIN=leaked.example\n')
    cfg = tmp_path / 'config.env'
    cfg.symlink_to(secret)
    monkeypatch.setattr(helper, 'CONFIG_FILE', cfg)
    monkeypatch.setattr(helper, 'UNIT_FILE', tmp_path / 'none')
    monkeypatch.setattr(helper, 'TOKEN_FILE', tmp_path / 'none2')
    helper.cmd_status()
    assert 'leaked.example' not in capsys.readouterr().out


def test_set_domain_is_audited_without_secrets(helper, cf_stub, monkeypatch):
    audits = []
    monkeypatch.setattr(helper, 'audit', audits.append)
    run_set_domain(helper, monkeypatch, 'API-SECRET')
    assert len(audits) == 1 and 'www.example.com' in audits[0] and 'API-SECRET' not in audits[0]

import subprocess
from types import SimpleNamespace

SECRET = 'SUPER-SECRET-TOKEN'
HDR = {'Origin': 'http://localhost'}


def fake_run_factory(calls, rc=0, out='Done.', err='Boom'):
    def fake(cmd, **kw):
        calls.append((cmd, kw))
        if cmd[:1] == ['sudo'] and 'rpi-webhost-config' in cmd[2]:
            return SimpleNamespace(returncode=rc, stdout=out, stderr=err)
        return SimpleNamespace(returncode=0, stdout='active\n', stderr='')
    return fake


def post(gui, data, **kw):
    c = gui.app.test_client()
    return c.post('/domain', data=data, headers=HDR, follow_redirects=True, **kw)


def helper_calls(calls):
    return [(c, kw) for c, kw in calls if c[:1] == ['sudo'] and 'rpi-webhost-config' in c[2]]


def test_set_token_passes_secret_via_stdin_only(gui, monkeypatch):
    calls = []
    monkeypatch.setattr(gui.subprocess, 'run', fake_run_factory(calls, out='Tunnel token replaced.'))
    r = post(gui, {'action': 'set_token', 'tunnel_token': SECRET})
    (cmd, kw), = helper_calls(calls)
    assert cmd == ['sudo', '-n', '/usr/local/sbin/rpi-webhost-config', 'set-token']
    assert SECRET not in ' '.join(cmd) and SECRET in kw['input']
    assert b'Tunnel token replaced.' in r.data and SECRET.encode() not in r.data


def test_set_domain_validates_and_passes_args(gui, monkeypatch):
    calls = []
    monkeypatch.setattr(gui.subprocess, 'run', fake_run_factory(calls))
    post(gui, {'action': 'set_domain', 'domain': 'Example.COM', 'api_token': SECRET})
    (cmd, kw), = helper_calls(calls)
    assert cmd[-2:] == ['set-domain', 'example.com'] and SECRET in kw['input'] and SECRET not in ' '.join(cmd)


def test_set_domain_rejects_invalid_domain_without_calling_helper(gui, monkeypatch):
    calls = []
    monkeypatch.setattr(gui.subprocess, 'run', fake_run_factory(calls))
    r = post(gui, {'action': 'set_domain', 'domain': 'x; rm -rf /', 'api_token': SECRET})
    assert helper_calls(calls) == [] and b'Invalid domain' in r.data


def test_helper_error_is_shown_and_secret_scrubbed(gui, monkeypatch):
    calls = []
    monkeypatch.setattr(gui.subprocess, 'run', fake_run_factory(calls, rc=1, err='bad %s here' % SECRET))
    r = post(gui, {'action': 'set_token', 'tunnel_token': SECRET})
    assert b'bad *** here' in r.data and SECRET.encode() not in r.data


def test_empty_token_never_reaches_helper(gui, monkeypatch):
    calls = []
    monkeypatch.setattr(gui.subprocess, 'run', fake_run_factory(calls))
    post(gui, {'action': 'set_token', 'tunnel_token': '   '})
    assert helper_calls(calls) == []


def test_timeout_is_reported(gui, monkeypatch):
    def boom(cmd, **kw):
        if cmd[:1] == ['sudo']:
            raise subprocess.TimeoutExpired(cmd, 90)
        return SimpleNamespace(returncode=0, stdout='active\n', stderr='')
    monkeypatch.setattr(gui.subprocess, 'run', boom)
    r = post(gui, {'action': 'set_token', 'tunnel_token': SECRET})
    assert b'timed out' in r.data


def test_csrf_still_enforced(gui):
    c = gui.app.test_client()
    assert c.post('/domain', data={'action': 'set_token', 'tunnel_token': SECRET}).status_code == 403
    assert c.post('/domain', data={'action': 'set_token', 'tunnel_token': SECRET},
                  headers={'Origin': 'http://evil.example'}).status_code == 403


# ── DNS rebinding: only loopback Host headers are served ──────────────────────

import pytest  # noqa: E402


@pytest.mark.parametrize('host', [
    'localhost', 'localhost:8080', '127.0.0.1:8080', '127.0.0.1', '127.1.2.3:9090', '[::1]:8080',
])
def test_loopback_hosts_are_served(gui, host):
    r = gui.app.test_client().get('/api/status', headers={'Host': host})
    assert r.status_code == 200


@pytest.mark.parametrize('host', [
    'attacker.example', 'attacker.example:8080', 'localhost.attacker.example:8080',
    '127.0.0.1.attacker.example', '127.0.0.1@attacker.example', '192.168.1.5:8080', '0.0.0.0:8080', '',
])
def test_non_loopback_hosts_are_refused_even_for_get(gui, host):
    r = gui.app.test_client().get('/api/status', headers={'Host': host})
    assert r.status_code == 403


def test_rebinding_post_is_refused_even_with_matching_origin(gui, monkeypatch):
    # Under rebinding the attacker's Origin and Host match each other, which the CSRF check alone accepts.
    calls = []
    monkeypatch.setattr(gui.subprocess, 'run', fake_run_factory(calls))
    r = gui.app.test_client().post('/domain', data={'action': 'set_token', 'tunnel_token': SECRET},
                                   headers={'Host': 'attacker.example:8080', 'Origin': 'http://attacker.example:8080'})
    assert r.status_code == 403 and helper_calls(calls) == []

import base64
import importlib.machinery
import importlib.util
import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
os.environ['RPI_WEBHOST_TEST'] = '1'


def load_helper():
    loader = importlib.machinery.SourceFileLoader('rpi_webhost_config', str(ROOT / 'bin' / 'rpi-webhost-config'))
    spec = importlib.util.spec_from_loader('rpi_webhost_config', loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


@pytest.fixture
def helper():
    return load_helper()


def make_token(a='a' * 32, t='11111111-2222-3333-4444-555555555555', s='c2VjcmV0K3NlY3JldC9zZWNyZXQ='):
    return base64.b64encode(json.dumps({'a': a, 't': t, 's': s}).encode()).decode()


@pytest.fixture
def token():
    return make_token()


@pytest.fixture
def gui(monkeypatch):
    sys.path.insert(0, str(ROOT / 'gui'))
    import app as gui_app
    gui_app.app.config['TESTING'] = True
    yield gui_app
    sys.path.remove(str(ROOT / 'gui'))
    sys.modules.pop('app', None)

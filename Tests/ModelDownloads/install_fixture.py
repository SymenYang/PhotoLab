"""Test bundle's entry point; not copied into production builds.
Redirects only model transport to loopback; reuses the production installer.
"""
import fcntl
import json
import os
from pathlib import Path
import signal
import sys
import urllib.parse
import urllib.request
import model_installer as installer

resources = Path(__file__).resolve().parent
config = json.loads((resources / 'simulation.json').read_text())
endpoint = config['endpoint']
parts = urllib.parse.urlparse(endpoint)
assert parts.scheme == 'http' and parts.hostname == '127.0.0.1'
root = Path(sys.argv[2]).resolve()
# Only freshly-created simulation workspaces are allowed; never fall back to HOME.
workspace = next((p for p in root.parents if (p / '.photolab-simulation').is_file()), None)
assert workspace is not None and str(workspace).startswith('/private/tmp/photolab-model-simulation-')
installer.RESOURCES = resources
original_open = urllib.request.urlopen
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def local_open(request, *args, **kwargs):
    url = request.full_url if isinstance(request, urllib.request.Request) else request
    assert url.startswith('https://huggingface.co/'), 'Unexpected outbound request: ' + url
    mapped = endpoint + url[len('https://huggingface.co'):]
    headers = dict(request.headers) if isinstance(request, urllib.request.Request) else {}
    return opener.open(urllib.request.Request(mapped, headers=headers), *args, **kwargs)
urllib.request.urlopen = local_open
# Synthetic dependency installation: create only an executable launcher inside the
# disposable runtime. The installer still performs its normal runtime readiness flow.
def fixture_run(arguments):
    if '-m' in arguments and 'venv' in arguments:
        runtime = Path(arguments[-1]).resolve()
        assert root in runtime.parents
        (runtime / 'bin').mkdir(parents=True, exist_ok=True)
        executable = runtime / 'bin/python3'
        executable.write_text('#!/bin/sh\nexec /usr/bin/python3 "$@"\n'); executable.chmod(0o755)
    elif 'pip' not in arguments and '-c' not in arguments:
        raise AssertionError(arguments)
    print('SIMULATION: synthetic Python dependencies, no pip/network', flush=True)
installer.run = fixture_run
if os.environ.get('SIMULATE_NO_SPACE') == '1':
    from collections import namedtuple
    installer.shutil.disk_usage = lambda _: namedtuple('usage', 'total used free')(100, 100, 0)
signal.signal(signal.SIGTERM, installer.stop)
try:
    root.mkdir(parents=True, exist_ok=True)
    with (root / 'install.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        installer.install(sys.argv[1], root, Path(sys.argv[3]))
except Exception as error:
    print('SIMULATION FAILURE: ' + str(error), flush=True)
    sys.exit(1)

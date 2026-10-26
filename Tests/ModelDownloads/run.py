#!/usr/bin/env python3
"""Real loopback HTTP + real child processes; all writes confined to mkdtemp.
Run with /usr/bin/python3. --ui retains the loopback server for manual UI checks.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from fixture import populate, REVISION, WEIGHTS
from server import Server

REPO = Path(__file__).resolve().parents[2]
WORKSPACE = Path(tempfile.mkdtemp(prefix='photolab-model-simulation-', dir='/private/tmp'))
(WORKSPACE / '.photolab-simulation').touch()
(WORKSPACE / 'server.pid').write_text(str(os.getpid()))
SERVER = None
APP = WORKSPACE / 'PhotoLab Model Simulation.app'
RESOURCES = APP / 'Contents/Resources/AI'
EXE = APP / 'Contents/MacOS/ModelSimulation'
RESULTS = []

def clean_env(root):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PHOTOLAB_', 'PYTHON', 'HF_', 'SIMULATE_'))}
    env.update(PHOTOLAB_DATA_DIR=str(root.parent), PYTHONDONTWRITEBYTECODE='1', NO_PROXY='127.0.0.1')
    return env

def fingerprint(path):
    digest = hashlib.sha256(); count = 0
    if not path.exists(): return dict(exists=False)
    # Metadata only: never read photo/model contents, follow symlinks or write originals.
    for directory, folders, files in os.walk(path, followlinks=False):
        for name in sorted(folders + files):
            item = Path(directory) / name
            st = item.lstat()
            digest.update(f'{item.relative_to(path)}|{st.st_mode}|{st.st_size}|{st.st_mtime_ns}\n'.encode())
            count += 1
        folders.sort()
    return dict(exists=True, entries=count, metadataSHA256=digest.hexdigest())

def protected_snapshot():
    paths = list(REPO.glob('.ai-model*')) + [REPO / '.ai-runtime',
        Path.home() / 'Library/Application Support/PhotoLab']
    local_config = REPO / '.local/ai-config.json'
    if local_config.exists():
        paths.extend(Path(p).parent if key in ('python', 'artPython') else Path(p)
                     for key, p in json.loads(local_config.read_text()).items()
                     if key in ('python', 'artPython', 'model', 'artModel', 'qwenModel', 'qwenCoreML', 'jarvisModel'))
    return {str(p): fingerprint(p) for p in paths}

def build():
    global MODEL
    EXE.parent.mkdir(parents=True)
    MODEL, SERVER.archive = populate(RESOURCES, SERVER.endpoint)
    shutil.copy2(REPO / 'AI/install_model.py', RESOURCES / 'model_installer.py')
    shutil.copy2(Path(__file__).with_name('install_fixture.py'), RESOURCES / 'install_model.py')
    (APP / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='local.photolab.model-simulation', CFBundleName='PhotoLab Model Simulation', CFBundleExecutable=EXE.name, CFBundlePackageType='APPL', LSUIElement=False)))
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(WORKSPACE / 'module-cache'))
    command = ['xcrun', 'swiftc', '-sdk', os.environ.get('PHOTOLAB_SDK', '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'),
        '-swift-version', '5', '-D', 'PHOTOLAB_MODEL_SIMULATION', '-parse-as-library',
        str(REPO / 'Sources/PhotoLab/ModelDownloads.swift'), str(REPO / 'Sources/PhotoLab/ModelService.swift'),
        str(REPO / 'Sources/PhotoLab/BackgroundTasks.swift'), str(Path(__file__).with_name('SimulationApp.swift')), '-o', str(EXE)]
    with (WORKSPACE / 'build.log').open('w') as log:
        subprocess.run(command, env=env, stdout=log, stderr=log, check=True)
    with (WORKSPACE / 'build-production-probe.log').open('w') as log:
        production = [arg for arg in command if arg not in ('-D', 'PHOTOLAB_MODEL_SIMULATION')]
        production[-1] = str(WORKSPACE / 'production-source-probe')
        subprocess.run(production, env=env, stdout=log, stderr=log, check=True)
    with (WORKSPACE / 'build-scheduler.log').open('w') as log:
        subprocess.run(['xcrun', 'swiftc', '-sdk', command[command.index('-sdk')+1], '-swift-version', '5', '-parse-as-library',
            str(REPO / 'Sources/PhotoLab/BackgroundTasks.swift'), str(REPO / 'Sources/PhotoLab/ModelService.swift'),
            str(REPO / 'Tests/ModelService/main.swift'), '-o', str(WORKSPACE / 'scheduler-tests')], env=env, stdout=log, stderr=log, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(APP)], check=True, capture_output=True)

class Cases(unittest.TestCase):
    def setUp(self):
        SERVER.mode = 'normal'; self.begin = len(SERVER.requests)
        self.root = WORKSPACE / self._testMethodName / 'AI'; self.root.mkdir(parents=True)
        self.consent = self.root / 'consent.json'
        self.consent.write_text(json.dumps(dict(MODEL, accepted=True, synthetic=True)))
        self.target = self.root / 'models/siglip' / REVISION
        self.processes = []; self.handles = []
    def tearDown(self):
        for p in self.processes:
            if p.poll() is None: p.kill(); p.wait()
        for handle in self.handles: handle.close()
    def start(self, env=None):
        log = (self.root.parent / ('install-%d.log' % len(self.processes))).open('w'); self.handles.append(log)
        process = subprocess.Popen(['/usr/bin/python3', '-B', str(RESOURCES / 'install_model.py'), 'siglip', str(self.root), str(self.consent)],
            env=dict(clean_env(self.root), **(env or {})), stdout=log, stderr=log)
        self.processes.append(process); return process
    def install(self, success=True, env=None):
        code = self.start(env).wait(timeout=25)
        self.assertEqual(code == 0, success, str(self.root.parent))
        return code
    def ready(self): return (self.target / 'installed.json').exists()
    def requests(self): return SERVER.requests[self.begin:]
    def wait_partial(self, process):
        part = self.target / 'model.safetensors.partial'
        until = time.monotonic() + 10
        while time.monotonic() < until:
            if part.exists() and part.stat().st_size >= 1024*1024: return part
            self.assertIsNone(process.poll(), 'installer exited early'); time.sleep(0.03)
        self.fail('no partial download')
    def probe(self, executable=EXE):
        result = subprocess.run([str(executable), '--probe'], env=clean_env(self.root), capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('inference = 0.42', result.stdout)
    def test_01_declined_and_stale_consent_never_network(self):
        for updates in [dict(accepted=False), dict(revision='b'*40), dict(licenseSHA256='stale')]:
            self.consent.write_text(json.dumps(dict(MODEL, accepted=True) | updates))
            self.install(False)
        self.assertEqual(self.requests(), []); self.assertFalse(self.ready())
        self.assertFalse((self.root / 'runtimes').exists())
    def test_02_normal_install_restart_cache_and_move(self):
        self.install(); self.assertTrue(self.ready()); self.probe()
        before = len([r for r in self.requests() if '/resolve/' in r['path']])
        self.install(); self.probe()
        self.assertEqual(before, len([r for r in self.requests() if '/resolve/' in r['path']]))
        moved = WORKSPACE / 'relocated/PhotoLab Model Simulation.app'
        shutil.copytree(APP, moved)
        self.probe(moved / 'Contents/MacOS/ModelSimulation')
    def test_03_cancel_then_range_resume(self):
        SERVER.mode = 'slow'; process = self.start(); part = self.wait_partial(process)
        process.terminate(); process.wait(timeout=10)
        self.assertFalse(self.ready()); self.assertGreater(part.stat().st_size, 0)
        SERVER.mode = 'normal'; self.install()
        self.assertTrue(any(r['range'] for r in self.requests())); self.assertTrue(self.ready())
    def test_04_killed_process_then_resume(self):
        SERVER.mode = 'slow'; process = self.start(); self.wait_partial(process)
        process.kill(); process.wait(timeout=10)
        self.assertFalse(self.ready()); SERVER.mode = 'normal'; self.install(); self.probe()
    def test_05_server_ignores_range(self):
        self.target.mkdir(parents=True); (self.target / 'model.safetensors.partial').write_bytes(WEIGHTS[:1024*1024])
        SERVER.mode = 'ignore-range'; self.install()
        self.assertEqual((self.target / 'model.safetensors').read_bytes(), WEIGHTS)
    def test_06_corrupt_then_retry(self):
        SERVER.mode = 'corrupt'; self.install(False); self.assertFalse(self.ready())
        SERVER.mode = 'normal'; self.install(); self.probe()
    def test_07_http_error_then_retry(self):
        SERVER.mode = 'http-error'; self.install(False); self.assertFalse(self.ready())
        SERVER.mode = 'normal'; self.install()
    def test_08_disk_full(self):
        self.install(False, dict(SIMULATE_NO_SPACE='1')); self.assertFalse(self.ready())
        self.assertFalse(any('/resolve/' in r['path'] for r in self.requests()))
    def test_09_connection_dropped_then_resume(self):
        SERVER.mode = 'drop'; self.install(False); self.assertFalse(self.ready())
        part = self.target / 'model.safetensors.partial'
        self.assertTrue(part.exists(), 'interrupted download must retain partial bytes')
        SERVER.mode = 'normal'; self.install()
        self.assertTrue(any(r['range'] for r in self.requests()))
    def test_10_full_swift_bootstrap_manager_and_inference(self):
        result = subprocess.run([str(EXE), '--install'], env=clean_env(self.root), capture_output=True, text=True, timeout=40)
        (self.root.parent / 'swift.log').write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any(r['path'] == '/python.tar.gz' for r in self.requests()))
        self.assertTrue(self.ready()); self.probe()
    def test_11_missing_download_file_is_not_ready(self):
        self.install(); (self.target / 'model.safetensors').unlink()
        result = subprocess.run([str(EXE), '--probe'], env=clean_env(self.root), capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.install(); self.probe()

    def test_12_stale_receipt_not_recognized(self):
        self.install()
        receipt = self.target / 'installed.json'
        original = json.loads(receipt.read_text())
        for update in [dict(revision='b'*40), dict(licenseSHA256='new-license'), dict(accepted=False)]:
            receipt.write_text(json.dumps(original | update))
            result = subprocess.run([str(EXE), '--probe'], env=clean_env(self.root), capture_output=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
        receipt.write_text(json.dumps(original)); self.probe()
    def test_13_bootstrap_corruption_never_installs(self):
        SERVER.mode = 'bad-bootstrap'
        result = subprocess.run([str(EXE), '--install'], env=clean_env(self.root), capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'python/bin/python3').exists()); self.assertFalse(self.ready())
        self.assertFalse(any('/api/models/' in r['path'] for r in self.requests()))
        SERVER.mode = 'normal'
        result = subprocess.run([str(EXE), '--install'], env=clean_env(self.root), capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0)
    def test_14_refresh_does_not_interrupt_inference(self):
        result = subprocess.run([str(WORKSPACE / 'scheduler-tests')], env=clean_env(self.root), capture_output=True, text=True, timeout=25)
        (self.root.parent / 'scheduler.log').write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    def test_15_production_build_has_no_simulation_source(self):
        result = subprocess.run([str(WORKSPACE / 'production-source-probe'), '--bootstrap-source'], env=clean_env(self.root), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith('https://github.com/astral-sh/python-build-standalone/'))
        self.assertNotIn(SERVER.endpoint, result.stdout)
        self.assertEqual(self.requests(), [])

    def test_16_legacy_local_models_without_download_receipts(self):
        legacy = WORKSPACE / 'legacy-model'; legacy.mkdir()
        (legacy / 'config.json').write_text('{}')
        (legacy / 'model.safetensors').write_bytes(b'legacy synthetic weights')
        legacy_app = WORKSPACE / 'legacy-app/PhotoLab Model Simulation.app'
        shutil.copytree(APP, legacy_app)
        (legacy_app / 'Contents/Resources/AI/config.json').write_text(json.dumps(dict(model=str(legacy), python='/usr/bin/python3')))
        subprocess.run(['codesign', '--force', '--sign', '-', str(legacy_app)], check=True, capture_output=True)
        # setUp created a consent file; use a separate completely empty user directory.
        fresh_root = WORKSPACE / 'legacy-user/AI'
        result = subprocess.run([str(legacy_app / 'Contents/MacOS/ModelSimulation'), '--probe-legacy'], env=clean_env(fresh_root), capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.requests(), [])

class RecordedResult(unittest.TextTestResult):
    def addSuccess(self, test): super().addSuccess(test); RESULTS.append(dict(test=test._testMethodName, status='passed'))
    def addFailure(self, test, err): super().addFailure(test, err); RESULTS.append(dict(test=test._testMethodName, status='failed', error=self._exc_info_to_string(err, test)))
    def addError(self, test, err): super().addError(test, err); RESULTS.append(dict(test=test._testMethodName, status='error', error=self._exc_info_to_string(err, test)))

def main():
    global SERVER
    parser = argparse.ArgumentParser(); parser.add_argument('--ui', action='store_true'); args = parser.parse_args()
    print('ISOLATED WORKSPACE:', WORKSPACE, flush=True)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    before = protected_snapshot()
    SERVER = Server()
    try:
        build()
        result = unittest.TextTestRunner(verbosity=2, resultclass=RecordedResult).run(unittest.defaultTestLoader.loadTestsFromTestCase(Cases))
        after = protected_snapshot()
        unchanged = before == after
        report = dict(workspace=str(WORKSPACE), passed=result.wasSuccessful() and unchanged, tests=RESULTS,
                      protectedPathsUnchanged=unchanged, before=before, after=after, requests=SERVER.requests)
        (WORKSPACE / 'report.json').write_text(json.dumps(report, indent=2))
        print('REPORT:', WORKSPACE / 'report.json', 'PROTECTED PATHS UNCHANGED:', unchanged, flush=True)
        if args.ui:
            SERVER.mode = 'slow'
            print('UI READY:', APP, '\nPHOTOLAB_DATA_DIR=' + str(WORKSPACE / 'manual-ui'), flush=True)
            while True: time.sleep(1)
        return 0 if report['passed'] else 1
    finally:
        SERVER.close()
        path = WORKSPACE / 'report.json'
        if path.exists():
            report = json.loads(path.read_text())
            report['finalProtectedPathsUnchanged'] = before == protected_snapshot()
            report['requests'] = SERVER.requests
            path.write_text(json.dumps(report, indent=2))

if __name__ == '__main__':
    try: sys.exit(main())
    except KeyboardInterrupt: pass

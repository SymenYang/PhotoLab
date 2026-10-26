import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import install_model as installer

class Response(io.BytesIO):
    def __init__(self, data, status=200, headers=None):
        super().__init__(data); self.status = status; self.headers = headers or {}

class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.target = self.root / 'weights'
        self.data = b'valid model bytes'
        self.sha = hashlib.sha256(self.data).hexdigest()
    def tearDown(self): self.temp.cleanup()
    def download(self): installer.download('https://example.com/model', self.target, len(self.data), self.sha)
    def test_resumes_and_verifies(self):
        self.target.with_suffix('.partial').write_bytes(self.data[:5])
        with patch('urllib.request.urlopen', return_value=Response(self.data[5:], 206, {'Content-Range': 'bytes 5-16/17'})) as request:
            self.download()
            self.assertEqual(request.call_args.args[0].headers['Range'], 'bytes=5-')
        self.assertEqual(self.target.read_bytes(), self.data)
    def test_server_ignoring_range_restarts(self):
        self.target.with_suffix('.partial').write_bytes(self.data[:5])
        with patch('urllib.request.urlopen', return_value=Response(self.data)):
            self.download()
        self.assertEqual(self.target.read_bytes(), self.data)
    def test_invalid_range_rejected(self):
        self.target.with_suffix('.partial').write_bytes(self.data[:5])
        with patch('urllib.request.urlopen', return_value=Response(self.data, 206, {'Content-Range': 'bytes 0-16/17'})):
            with self.assertRaises(ValueError): self.download()
        self.assertFalse(self.target.exists())
    def test_corruption_never_published(self):
        with patch('urllib.request.urlopen', return_value=Response(b'!' * len(self.data))):
            with self.assertRaises(ValueError): self.download()
        self.assertFalse(self.target.exists())
        self.assertFalse(self.target.with_suffix('.partial').exists())
    def test_valid_cached_file_avoids_network(self):
        self.target.write_bytes(self.data)
        with patch('urllib.request.urlopen', side_effect=AssertionError('network')):
            self.download()
    def test_rejects_stale_or_absent_consent_before_network_or_pip(self):
        manifest = json.loads((installer.RESOURCES / 'models.json').read_text())[0]
        for consent in ({}, dict(manifest, accepted=False), dict(manifest, accepted=True, revision='stale'), dict(manifest, accepted=True, licenseSHA256='stale')):
            path = self.root / 'consent.json'; path.write_text(json.dumps(consent))
            with patch('urllib.request.urlopen', side_effect=AssertionError('network')), patch.object(installer, 'run', side_effect=AssertionError('pip')):
                with self.assertRaises(ValueError): installer.install(manifest['id'], self.root, path)
    def test_manifest_licenses_match_and_pins_are_immutable(self):
        for model in json.loads((installer.RESOURCES / 'models.json').read_text()):
            self.assertRegex(model['revision'], r'^[0-9a-f]{40}$')
            self.assertEqual(installer.digest(installer.RESOURCES / 'licenses' / model['license']), model['licenseSHA256'])
    def test_success_publishes_receipt_only_after_verified_files(self):
        model = json.loads((installer.RESOURCES / 'models.json').read_text())[0]
        consent = self.root / 'consent.json'; consent.write_text(json.dumps(dict(model, accepted=True)))
        runtime = self.root / 'runtimes' / model['environment']
        (runtime / 'bin').mkdir(parents=True)
        (runtime / 'bin/python3').touch()
        installer.atomic_json(runtime / 'photolab-ready.json', {'lock': installer.digest(installer.RESOURCES / 'requirements.lock')})
        metadata = dict(sha=model['revision'], siblings=[dict(rfilename='model.safetensors', lfs=dict(size=len(self.data), sha256=self.sha))])
        with patch('urllib.request.urlopen', side_effect=[Response(json.dumps(metadata).encode()), Response(self.data)]), patch.object(installer, 'run', side_effect=AssertionError('pip')):
            installer.install(model['id'], self.root, consent)
        target = self.root / 'models' / model['id'] / model['revision']
        self.assertEqual((target / 'model.safetensors').read_bytes(), self.data)
        receipt = json.loads((target / 'installed.json').read_text())
        self.assertTrue(receipt['accepted'])
        self.assertEqual(receipt['files'], ['model.safetensors'])
        self.assertEqual(installer.digest(target / model['license']), model['licenseSHA256'])
        self.assertEqual(json.loads((target / 'photolab-model.json').read_text())['revision'], model['revision'])
    def test_failed_install_never_creates_receipt(self):
        model = json.loads((installer.RESOURCES / 'models.json').read_text())[0]
        consent = self.root / 'consent.json'; consent.write_text(json.dumps(dict(model, accepted=True)))
        with patch.object(installer, 'run', side_effect=RuntimeError('offline')):
            with self.assertRaises(RuntimeError): installer.install(model['id'], self.root, consent)
        self.assertEqual(list(self.root.rglob('installed.json')), [])

if __name__ == '__main__': unittest.main()

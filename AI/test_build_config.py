"""Compatibility regression: distribution configuration must not erase local setup."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

class BuildConfigurationTests(unittest.TestCase):
    def test_clean_checkout_needs_no_local_configuration(self):
        script = Path(__file__).resolve().parents[1] / 'scripts/write-ai-config.py'
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            app = root / 'build/PhotoLab.app'
            subprocess.run(['/usr/bin/python3', '-B', str(script), '--project', str(root), '--app', str(app)], check=True)
            config = json.loads((app / 'Contents/Resources/AI/config.json').read_text())
            self.assertNotIn('artModel', config)
            self.assertNotIn('jarvisModel', config)
            self.assertEqual(config['jarvisPrompt'], str(app / 'Contents/Resources/AI/jarvis_prompt.py'))

    def test_distribution_output_preserves_local_config(self):
        script = Path(__file__).resolve().parents[1] / 'scripts/write-ai-config.py'
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            local = root / 'build/PhotoLab.app'
            distribution = root / 'build/PhotoLab-Distribution.app'
            args = ['/usr/bin/python3', '-B', str(script), '--project', str(root)]
            (root / '.local').mkdir()
            overrides = {'artModel': str(root / 'offline/model'), 'artPython': str(root / 'offline/bin/python')}
            (root / '.local/ai-config.json').write_text(json.dumps(overrides))
            subprocess.run(args + ['--app', str(local)], check=True)
            config_path = local / 'Contents/Resources/AI/config.json'
            before = config_path.read_bytes()
            config = json.loads(before)
            self.assertEqual(config['model'], str(root / '.ai-model'))
            self.assertEqual(config['artModel'], overrides['artModel'])
            self.assertEqual(config['artPython'], overrides['artPython'])
            self.assertEqual(config['qwenModel'], str(root / '.ai-model-qwen'))
            subprocess.run(args + ['--app', str(distribution), '--distribution'], check=True)
            self.assertEqual(json.loads((distribution / 'Contents/Resources/AI/config.json').read_text()), {})
            self.assertEqual(config_path.read_bytes(), before)

import importlib.util
import os
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("color_worker", ROOT / "AI/color_worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class ColorWorkerTests(unittest.TestCase):
    def test_generation_rejects_untranslated_input_before_loading_models(self):
        for prompt in ["电影感", "cinematic 保留肤色", "電影感", "", "\U00020000"]:
            with self.assertRaisesRegex(ValueError, "Apple"):
                worker.run({"prompt": prompt}, Path("/missing"))

    def test_english_bypasses_translation_model(self):
        self.assertEqual(worker.translate("cinematic look", "/missing"), "cinematic look")

    def test_extract_json_and_python_literals(self):
        self.assertEqual(worker.extract('<answer>{"Exposure2012": 0.5}</answer>'), {"Exposure2012": 0.5})
        self.assertEqual(worker.extract("<answer>{'ConvertToGrayscale': True}</answer>"), {"ConvertToGrayscale": True})
        for invalid in ["nothing", "<answer>{}</answer>", '<answer>{"Exposure2012": NaN}</answer>', "<answer>{broken</answer>"]:
            with self.assertRaises(ValueError):
                worker.extract(invalid)

    def test_scope_and_curve_serialization(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.xmp"
            skipped = worker.preset({"Exposure2012": 0.5, "ToneCurvePV2012": {"0": 0, "1": 0, "2": 255, "3": 240},
                "MaskGroupBasedCorrections": {"0": {"Exposure": 1}}, "CropTop": 0.2, "CameraProfile": "Adobe Color"}, path)
            self.assertEqual(set(skipped), {"MaskGroupBasedCorrections", "CropTop", "CameraProfile"})
            tree = ET.parse(path)
            self.assertEqual([item.text for item in tree.findall(f".//{{{worker.RDF}}}li")], ["0, 0", "255, 240"])
            self.assertNotIn("CropTop", path.read_text())
            with self.assertRaises(ValueError):
                worker.preset({"ToneCurvePV2012": [255, 255, 0, 0]}, path)

    @unittest.skipUnless(os.environ.get("PHOTOLAB_COLOR_FIXTURES"), "external experiment fixtures not supplied")
    def test_existing_experiment_answers(self):
        paths = sorted(Path(os.environ["PHOTOLAB_COLOR_FIXTURES"]).glob("*.json"))
        self.assertTrue(paths, "fixture directory has no JSON files")
        for path in paths:
            import json
            result = json.loads(path.read_text())
            if "parameters" not in result:
                continue
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "test.xmp"
                worker.preset(result["parameters"], output)
                ET.parse(output)

    def test_system_prompt(self):
        prompt = worker.system_prompt(ROOT / "AI/jarvis_prompt.py")
        self.assertIn("<answer>", prompt)
        self.assertGreater(len(prompt), 1000)

    @unittest.skipUnless((ROOT / ".ai-model-zh-en/pytorch_model.bin").exists(), "local translator not downloaded")
    def test_local_translation_preserves_photo_terms(self):
        import torch
        torch.set_num_threads(4)
        model = str(ROOT / ".ai-model-zh-en")
        portrait = worker.translate("电影感，保留自然肤色，柔和高光，冷色阴影", model)
        for term in ["cinematic look", "natural skin tones", "highlights", "cool-toned", "shadows"]:
            self.assertIn(term, portrait)
        moriyama = worker.translate("森山大道的风格，粗粝、高反差的黑白摄影", model)
        for term in ["Daido Moriyama", "gritty texture", "high contrast", "black-and-white photography"]:
            self.assertIn(term, moriyama)
        negative = worker.translate("不要改变肤色，轻微增加对比度", model)
        self.assertIn("not", negative.lower())
        self.assertIn("skin tones", negative)
        self.assertIn("contrast", negative)


if __name__ == "__main__":
    unittest.main()

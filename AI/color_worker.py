import os
os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", TOKENIZERS_PARALLELISM="false")
os.environ.pop("PYTORCH_ENABLE_MPS_FALLBACK", None)

import ast
import gc
import json
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

CRS = "http://ns.adobe.com/camera-raw-settings/1.0/"
RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
CURVES = {"ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue"}
TERMS = {
    "森山大道": "Daido Moriyama", "电影感": "cinematic look", "電影感": "cinematic look",
    "自然肤色": "natural skin tones", "肤色": "skin tones", "膚色": "skin tones",
    "高反差": "high contrast", "低反差": "low contrast", "对比度": "contrast", "對比度": "contrast",
    "黑白摄影": "black-and-white photography", "黑白": "black and white", "粗粝": "gritty texture",
    "高光": "highlights", "阴影": "shadows", "陰影": "shadows", "冷色": "cool-toned", "暖色": "warm-toned",
    "自然饱和度": "vibrance", "饱和度": "saturation", "色温": "color temperature", "白平衡": "white balance",
    "曝光": "exposure", "色相": "hue", "颗粒": "grain", "暗角": "vignette", "褪色": "faded colors",
}
GLOBAL = re.compile(r"^(Exposure2012|Contrast2012|Highlights2012|Shadows2012|Whites2012|Blacks2012|"
                    r"Temperature|Tint|WhiteBalance|IncrementalTemperature|IncrementalTint|"
                    r"Texture|Clarity2012|Dehaze|Vibrance|Saturation|ConvertToGrayscale|"
                    r"(?:Hue|Saturation|Luminance)Adjustment(?:Red|Orange|Yellow|Green|Aqua|Blue|Purple|Magenta)|"
                    r"GrayMixer(?:Red|Orange|Yellow|Green|Aqua|Blue|Purple|Magenta)|"
                    r"SplitToning(?:ShadowHue|ShadowSaturation|HighlightHue|HighlightSaturation|Balance)|"
                    r"ColorGrade(?:MidtoneHue|MidtoneSat|ShadowLum|MidtoneLum|HighlightLum|Blending|GlobalHue|GlobalSat|GlobalLum)|"
                    r"Parametric(?:Shadows|Darks|Lights|Highlights|ShadowSplit|MidtoneSplit|HighlightSplit)|"
                    r"PostCropVignette(?:Amount|Midpoint|Feather|Roundness|Style|HighlightContrast)|"
                    r"GrainAmount|GrainSize|GrainFrequency|Sharpness|SharpenRadius|SharpenDetail|SharpenEdgeMasking|"
                    r"LuminanceSmoothing|LuminanceNoiseReductionDetail|LuminanceNoiseReductionContrast|"
                    r"ColorNoiseReduction|ColorNoiseReductionDetail|ColorNoiseReductionSmoothness)$")


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False))
    temporary.replace(path)


def translate(text, model_path):
    if not re.search(r"[\u3400-\u9fff]", text):
        return text
    import torch
    from transformers import MarianMTModel, MarianTokenizer
    tokenizer = MarianTokenizer.from_pretrained(model_path, local_files_only=True)
    model = MarianMTModel.from_pretrained(model_path, local_files_only=True).eval()
    translated = []
    for clause in filter(str.strip, re.split(r"[，,；;。！!\n]+", text)):
        if not re.search(r"[\u3400-\u9fff]", clause):
            translated.append(clause.strip().rstrip(". "))
            continue
        protected = []
        def protect(match):
            protected.append(TERMS[match[0]])
            return f"PHOTOTERM{len(protected)-1}"
        prepared = re.sub("|".join(map(re.escape, sorted(TERMS, key=len, reverse=True))), protect, clause)
        inputs = tokenizer(prepared, return_tensors="pt", truncation=False)
        if inputs.input_ids.shape[1] > 450:
            raise ValueError("中文意图过长，请缩短到约200字")
        with torch.inference_mode():
            result = model.generate(**inputs, max_new_tokens=256, num_beams=4)
        if result.shape[1] >= 257 or result[0, -1].item() != tokenizer.eos_token_id:
            raise ValueError("翻译被截断，请缩短调色意图")
        english = tokenizer.decode(result[0], skip_special_tokens=True).strip()
        for index in reversed(range(len(protected))):
            pattern = rf"PHOTOTERM\s*{index}(?!\d)"
            if not re.search(pattern, english, re.I):
                raise ValueError("翻译遗漏摄影术语，请改写或直接输入英文")
            english = re.sub(pattern, protected[index], english, flags=re.I)
        if not english or re.search(r"[\u3400-\u9fff]|PHOTOTERM", english, re.I):
            raise ValueError("未能完整翻译，请改用英文")
        translated.append(english.rstrip(". "))
    english = "; ".join(translated) + "."
    del model, tokenizer
    gc.collect()
    return english


def system_prompt(path):
    strings = {}
    for node in ast.parse(Path(path).read_text()).body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                strings[node.targets[0].id] = node.value.value
            elif isinstance(node.value, ast.BinOp) and isinstance(node.value.op, ast.Add):
                strings[node.targets[0].id] = strings[node.value.left.id] + ast.literal_eval(node.value.right)
    return strings["SHORT_SYSTEM_PROMPT_WITH_THINKING"]


def extract(text):
    match = re.search(r"<answer>(.*?)</answer>", text, re.S)
    if not match:
        raise ValueError("JarvisArt 没有返回完整 answer，未应用参数")
    body = match[1]
    body = body[body.find("{"):body.rfind("}") + 1]
    for parser in (json.loads, ast.literal_eval):
        try:
            result = parser(body)
            if isinstance(result, dict) and result:
                json.dumps(result, allow_nan=False)
                return result
        except (ValueError, SyntaxError, TypeError):
            pass
    raise ValueError("JarvisArt 参数格式无效，未应用参数")


def preset(parameters, path):
    root = ET.Element("{adobe:ns:meta/}xmpmeta")
    description = ET.SubElement(ET.SubElement(root, f"{{{RDF}}}RDF"), f"{{{RDF}}}Description")
    skipped = []
    for key, value in parameters.items():
        if key in CURVES:
            values = [value[index] for index in sorted(value, key=int)] if isinstance(value, dict) else value
            if not isinstance(values, list) or not values:
                raise ValueError("无效的色调曲线")
            if all(isinstance(item, str) and "," in item for item in values):
                pairs = [tuple(float(number) for number in item.split(",")) for item in values]
            else:
                if len(values) % 2:
                    raise ValueError("色调曲线坐标不完整")
                pairs = list(zip(values[::2], values[1::2]))
            if len(pairs) < 2 or not all(len(pair) == 2 and all(isinstance(number, (float, int)) and 0 <= number <= 255 for number in pair) for pair in pairs):
                raise ValueError("色调曲线超出范围")
            if not all(pairs[index][0] < pairs[index + 1][0] for index in range(len(pairs) - 1)):
                raise ValueError("色调曲线必须单调排列")
            sequence = ET.SubElement(ET.SubElement(description, f"{{{CRS}}}{key}"), f"{{{RDF}}}Seq")
            for horizontal, vertical in pairs:
                ET.SubElement(sequence, f"{{{RDF}}}li").text = f"{horizontal:g}, {vertical:g}"
        elif GLOBAL.fullmatch(key) and isinstance(value, (str, bool, int, float)):
            description.set(f"{{{CRS}}}{key}", str(value).lower() if isinstance(value, bool) else str(value))
        else:
            skipped.append(key)
    description.set(f"{{{CRS}}}PresetType", "Normal")
    description.set(f"{{{CRS}}}Name", "PhotoLab JarvisArt")
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
    return skipped


def run(request, directory):
    english = request["prompt"].strip()
    if not english or re.search(r"[\u3400-\u9fff\uf900-\ufaff\U00020000-\U000323af]", english):
        raise ValueError("请先用 Apple 翻译成英文并检查，再生成调色。")
    import torch
    torch.set_num_threads(4)
    torch.manual_seed(42)
    status_path = directory / "status.json"
    def status(message, english=""):
        write_json(status_path, {"message": message, "english": english})
    status("正在加载本地 JarvisArt（约16GB）…", english)
    from PIL import Image
    from transformers import AutoModelForImageTextToText, AutoProcessor, StoppingCriteria, StoppingCriteriaList
    if not torch.backends.mps.is_available():
        raise RuntimeError("Metal GPU 不可用，无法运行本地 JarvisArt")
    processor = AutoProcessor.from_pretrained(request["model"], local_files_only=True, use_fast=False,
                                            min_pixels=256*256, max_pixels=768*768)
    model, loading = AutoModelForImageTextToText.from_pretrained(request["model"], local_files_only=True,
        dtype=torch.bfloat16, attn_implementation="sdpa", output_loading_info=True)
    if any(loading[key] for key in ("missing_keys", "unexpected_keys", "mismatched_keys")):
        raise RuntimeError("JarvisArt 权重不完整")
    model.eval().to("mps")
    messages = [{"role": "system", "content": system_prompt(request["systemPrompt"])},
                {"role": "user", "content": [{"type": "image"}, {"type": "text", "text": english}]}]
    prompt = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = processor(text=[prompt], images=[Image.open(request["image"]).convert("RGB")], return_tensors="pt").to("mps")
    started = time.monotonic()
    class Progress(StoppingCriteria):
        steps = 0
        timed_out = False
        def __call__(self, input_ids, scores, **kwargs):
            self.steps += 1
            if self.steps % 30 == 0:
                status(f"JarvisArt 正在生成调色方案 · {self.steps} tokens · {int(time.monotonic()-started)} 秒", english)
            self.timed_out = time.monotonic() - started > 900
            return self.timed_out
    progress = Progress()
    status("JarvisArt 正在分析图片；通常需要数分钟…", english)
    with torch.inference_mode():
        output = model.generate(**inputs, do_sample=False, max_new_tokens=4096, stopping_criteria=StoppingCriteriaList([progress]))
    tokens = output[0, inputs.input_ids.shape[1]:].tolist()
    response = processor.decode(tokens, skip_special_tokens=True)
    (directory / "response.txt").write_text(response)
    endings = model.generation_config.eos_token_id
    endings = endings if isinstance(endings, list) else [endings]
    if progress.timed_out or not tokens or tokens[-1] not in endings:
        raise ValueError("生成超时或被截断，未应用不完整参数")
    parameters = extract(response)
    del model, processor, inputs, output
    gc.collect()
    torch.mps.empty_cache()
    status("正在导入 Redlamp 并核对操作…", english)
    xmp = directory / "result.xmp"
    skipped = preset(parameters, xmp)
    imported = subprocess.run([request["redlamp"], "recipe", "import", str(xmp), "-o", str(directory / "result.redrecipe")],
                              capture_output=True, text=True, timeout=60, check=True)
    recipe = json.loads((directory / "result.redrecipe").read_text())
    return {"english": english, "recipe": recipe, "parameters": parameters, "response": response,
            "audit": imported.stdout + imported.stderr + "\nPhotoLab 未应用（非本版全局调色范围）：" + ", ".join(skipped)}


if __name__ == "__main__":
    directory = Path(sys.argv[1]).parent
    try:
        write_json(directory / "result.json", run(json.loads(Path(sys.argv[1]).read_text()), directory))
    except Exception as error:
        write_json(directory / "error.json", {"error": str(error)})
        raise

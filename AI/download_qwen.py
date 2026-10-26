"""Download pinned official Qwen weights for local comparison. No photo access."""
import json
from pathlib import Path
from huggingface_hub import snapshot_download
from model_consent import confirm
confirm('qwen')
model = 'Qwen/Qwen3-VL-Embedding-2B'
revision = '9f2f7e710d6d81056aa5c0a4f04764fec6bb7bda'
target = Path(__file__).resolve().parent.parent / '.ai-model-qwen'
snapshot_download(model, revision=revision, local_dir=target, allow_patterns=['*.json', '*.safetensors', '*.txt', '*.jinja'])
(target / 'photolab-model.json').write_text(json.dumps({'model': model, 'revision': revision}))
print(f'Ready: {model}@{revision}')

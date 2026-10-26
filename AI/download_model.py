"""Download model weights only; no photograph is read by this setup script."""
import json
import os
from pathlib import Path
from huggingface_hub import snapshot_download
from model_consent import confirm
confirm('siglip')
model = "google/siglip2-base-patch16-256"
target = Path(__file__).resolve().parent.parent / ".ai-model"
revision = "3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab"
snapshot_download(model, revision=revision, local_dir=target, allow_patterns=["*.json", "*.model", "*.txt", "*.safetensors"])
(target / "photolab-model.json").write_text(json.dumps({"model": model, "revision": revision}))
print(f"Ready: {model}@{revision}", flush=True)

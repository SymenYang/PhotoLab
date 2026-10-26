"""Local Q-ReAlign IAA worker. Durable raw scores; no media or catalog writes."""
import os
os.environ.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false")
os.environ.pop("PYTORCH_ENABLE_MPS_FALLBACK", None)
import contextlib
import json
import math
import sqlite3
import sys
import time
from pathlib import Path

class Engine:
    def __init__(self, model, database, task="art"):
        self.task = task
        self.attribute = "quality" if task == "quality" else "aesthetics"
        self.path = Path(model)
        revision = json.loads((self.path.parent / "model-revision.json").read_text())
        self.revision = revision
        self.key = ("q-realign-iqa-768-sdr-v1/" if task == "quality" else "q-realign-iaa-768-sdr-v1/") + json.dumps(revision, sort_keys=True)
        self.db = sqlite3.connect(database)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("CREATE TABLE IF NOT EXISTS scores(id TEXT PRIMARY KEY,fingerprint TEXT,model TEXT,raw REAL,updated REAL)")
        self.model = None

    def load(self):
        if self.model is not None:
            return
        import torch
        from transformers import AutoProcessor, AutoModelForImageTextToText
        torch.set_num_threads(2)
        if not torch.backends.mps.is_available():
            raise RuntimeError("模型艺术打分需要 Metal GPU")
        self.torch = torch
        self.processor = AutoProcessor.from_pretrained(self.path, local_files_only=True, padding_side="left")
        model, info = AutoModelForImageTextToText.from_pretrained(self.path, local_files_only=True, dtype=torch.bfloat16, attn_implementation="sdpa", output_loading_info=True)
        if info["missing_keys"] or info["mismatched_keys"]:
            raise RuntimeError("模型权重不完整")
        self.model = model.eval().to("mps")
        self.ids = [self.processor.tokenizer(" " + level, add_special_tokens=False).input_ids[0] for level in ["excellent", "good", "fair", "poor", "bad"]]
        self.weights = torch.tensor([1, .75, .5, .25, 0], device="mps")
        self.configure_prompt()

    def set_task(self, task):
        self.task = task
        self.attribute = "quality" if task == "quality" else "aesthetics"
        self.key = ("q-realign-iqa-768-sdr-v1/" if task == "quality" else "q-realign-iaa-768-sdr-v1/") + json.dumps(self.revision, sort_keys=True)
        if self.model is not None:
            self.configure_prompt()

    def configure_prompt(self):
        messages = [{"role":"user","content":[{"type":"image"},{"type":"text","text":f"How would you rate the {self.attribute} of this image?"}]}]
        self.prompt = self.processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False) + f"The {self.attribute} of the image is"

    def request(self, req):
        if req["command"] == "status":
            rows = list(self.db.execute("SELECT id,fingerprint,raw FROM scores WHERE model=?", (self.key,)))
            return dict(fingerprints={r[0]:r[1] for r in rows}, artScores={r[0]:r[2] for r in rows})
        if req["command"] not in ("index", "score"):
            raise ValueError("Unknown command")
        row = self.db.execute("SELECT raw FROM scores WHERE id=? AND fingerprint=? AND model=?", (req["id"], req["fingerprint"], self.key)).fetchone() if req["command"] == "index" else None
        if row:
            return dict(rawScore=row[0], device="mps")
        self.load()
        from PIL import Image
        with Image.open(req["path"]) as image:
            inputs = self.processor(text=[self.prompt], images=[image.convert("RGB")], padding=True, return_tensors="pt").to("mps")
        with self.torch.inference_mode():
            logits = self.model(**inputs, use_cache=False, logits_to_keep=1).logits[:, -1, self.ids]
            raw = (logits.float().softmax(-1) * self.weights).sum(-1).item()
        if not math.isfinite(raw) or not 0 <= raw <= 1:
            raise ValueError("Invalid model score")
        if req["command"] == "index":
          with self.db:
            self.db.execute("INSERT OR REPLACE INTO scores VALUES(?,?,?,?,?)", (req["id"],req["fingerprint"],self.key,raw,time.time()))
        return dict(rawScore=raw,device="Metal GPU")

def main():
    with contextlib.redirect_stdout(sys.stderr):
        engine = Engine(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "art")
    for line in sys.stdin:
        try:
            with contextlib.redirect_stdout(sys.stderr):
                result = engine.request(json.loads(line))
            print(json.dumps(dict(ok=True, **result)), flush=True)
        except Exception as error:
            print(json.dumps(dict(ok=False, error=str(error))), flush=True)

if __name__ == "__main__":
    main()

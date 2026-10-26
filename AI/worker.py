"""Local-only SigLIP 2 JSON-lines worker. Never receives an upload destination."""
import os
os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false")
import hashlib
import contextlib
import json
import sqlite3
import sys
import time
from pathlib import Path

MODEL_ID = "google/siglip2-base-patch16-256"
PIPELINE = "imageio-sdr-srgb-512-rotation-v1/siglip2-256-cosine-v1"

class Engine:
    def __init__(self, model_path, database):
        import numpy as np
        self.np = np
        self.model_path = model_path
        revision = json.loads((Path(model_path) / "photolab-model.json").read_text())["revision"]
        self.key = MODEL_ID + "@" + revision + "/" + PIPELINE
        Path(database).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(database)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("CREATE TABLE IF NOT EXISTS embeddings (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, model TEXT NOT NULL, vector BLOB NOT NULL)")
        self.model = self.processor = None
        self.device = "未加载"
        self.text_cache = {}
        self._fingerprints = None
        self._vectors = None
        self._data_version = None

    def check_index(self):
        version = (self.key, self.db.execute('PRAGMA data_version').fetchone()[0], self.db.total_changes)
        if version != self._data_version:
            self._fingerprints = self._vectors = None
            self._data_version = version

    def fingerprints(self):
        self.check_index()
        if self._fingerprints is None:
            self._fingerprints = dict(self.db.execute('SELECT id,fingerprint FROM embeddings WHERE model=?', (self.key,)))
        return self._fingerprints

    def vectors(self):
        self.check_index()
        if self._vectors is None:
            rows = list(self.db.execute('SELECT id,fingerprint,vector FROM embeddings WHERE model=?', (self.key,)))
            ids = [r[0] for r in rows]
            matrix = self.np.stack([self.np.frombuffer(r[2],dtype=self.np.float32) for r in rows]) if rows else self.np.empty((0,0), dtype=self.np.float32)
            self._vectors = (ids, [r[1] for r in rows], matrix, {id:i for i,id in enumerate(ids)})
        return self._vectors

    def load(self):
        if self.model is not None:
            return
        import torch
        from transformers import AutoModel, AutoProcessor
        torch.set_num_threads(2)
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.processor = AutoProcessor.from_pretrained(self.model_path, local_files_only=True, use_fast=False)
        self.model = AutoModel.from_pretrained(self.model_path, local_files_only=True, dtype=torch.float32).eval().to(self.device)
        self.torch = torch

    def normalize(self, features):
        if not hasattr(features, "norm"):
            features = features.pooler_output
        features = features / features.norm(dim=-1, keepdim=True).clamp(min=1e-12)
        return features.float().cpu().numpy()[0].astype(self.np.float32)

    def image_vector(self, path):
        self.load()
        from PIL import Image
        with Image.open(path) as image:
            inputs = self.processor(images=image.convert("RGB"), return_tensors="pt").to(self.device)
        with self.torch.inference_mode():
            return self.normalize(self.model.get_image_features(**inputs))

    def text_vector(self, text):
        self.load()
        if len(self.processor.tokenizer(text, add_special_tokens=True)["input_ids"]) > 64:
            raise ValueError("描述超过模型的 64 token 限制，请缩短后重试。")
        inputs = self.processor(text=[text], padding="max_length", max_length=64, truncation=True, return_tensors="pt").to(self.device)
        with self.torch.inference_mode():
            return self.normalize(self.model.get_text_features(**inputs))

    def cluster(self, request):
        # Complete-link groups: every pair must pass, never transitive chains.
        threshold = float(request.get("threshold", 0.98))
        if not -1.0 <= threshold <= 1.0:
            raise ValueError("Similarity threshold must be between -1.0 and 1.0")
        ids, fingerprints, matrix, positions = self.vectors()
        candidates = request["photos"]
        eligible = sorted((p for p in candidates if p["id"] in positions
                           and fingerprints[positions[p["id"]]] == p["fingerprint"]
                           and p.get("capture") is not None),
                          key=lambda p: (p["root"], p["folder"], p["day"], p["capture"], p["id"]))
        signature = hashlib.sha256(json.dumps([self.key, "complete-link-v3-24h-64", threshold, eligible],
                                              sort_keys=True).encode()).hexdigest()
        self.db.execute("CREATE TABLE IF NOT EXISTS similarity_cache (id INTEGER PRIMARY KEY, signature TEXT, groups_json TEXT)")
        cached = self.db.execute("SELECT groups_json FROM similarity_cache WHERE id=1 AND signature=?", (signature,)).fetchone()
        if cached:
            return json.loads(cached[0])
        groups, active = [], []
        for photo in eligible:
            scope = (photo["root"], photo["folder"], photo["day"])
            active = [g for g in active if g[0] == scope and photo["capture"] - g[1] <= 24 * 60 * 60]
            index = positions[photo["id"]]
            best, best_score = None, float("-inf")
            for group in active:
                if len(group[2]) >= 64:
                    continue
                score = float((matrix[group[2]] @ matrix[index]).min())
                if score >= threshold and score > best_score:
                    best, best_score = group, score
            if best is None:
                best = [scope, photo["capture"], [], []]
                active.append(best)
                groups.append(best)
            best[2].append(index)
            best[3].append(photo["id"])
        result = [g[3] for g in groups if len(g[3]) > 1]
        self.db.execute("INSERT OR REPLACE INTO similarity_cache VALUES(1,?,?)", (signature, json.dumps(result)))
        self.db.commit()
        return result

    def handle(self, request):
        start = time.monotonic()
        self.check_index()
        command = request["command"]
        if command == "preload":
            self.load()
            result = {}
        elif command == "status":
            result = {"fingerprints": self.fingerprints()}
        elif command == "index":
            vector = self.image_vector(request["path"])
            self.check_index()
            self.db.execute("INSERT OR REPLACE INTO embeddings VALUES(?,?,?,?)", (request["id"], request["fingerprint"], self.key, vector.tobytes()))
            self.db.commit()
            self._vectors = None
            self._data_version = (self.key, self.db.execute('PRAGMA data_version').fetchone()[0], self.db.total_changes)
            if self._fingerprints is not None:
                self._fingerprints[request['id']] = request['fingerprint']
            result = {"dimension": len(vector)}
        elif command == "cluster":
            result = {"groups": self.cluster(request)}
        elif command == "search":
            candidates = request["candidates"]
            ids, fingerprints, matrix, positions = self.vectors()
            eligible = [i for i, (id,fp) in enumerate(zip(ids,fingerprints)) if candidates.get(id) == fp]
            if not eligible:
                raise ValueError("当前范围没有有效的照片索引，请先建立或更新索引。")
            reference = request.get("reference")
            if reference:
                index = positions.get(reference)
                if index is None or candidates.get(reference) != fingerprints[index]:
                    raise ValueError("参考照片尚未建立索引，或旋转/文件已变化，请更新索引。")
                query = matrix[index]
            else:
                text = request["text"].strip()
                if text not in self.text_cache:
                    if len(self.text_cache) >= 32:
                        self.text_cache.pop(next(iter(self.text_cache)))
                    self.text_cache[text] = self.text_vector(text)
                query = self.text_cache[text]
            scores = matrix @ query
            eligible = self.np.asarray(eligible)
            order = eligible[self.np.argsort(-scores[eligible], kind="stable")]
            hits = [{"id": ids[i], "score": float(scores[i])} for i in order if ids[i] != reference]
            if reference:
                hits.insert(0, {"id": reference, "score": 1.0})
            result = {"hits": hits, "searched": len(eligible)}
        else:
            raise ValueError("Unknown command")
        result.update(ok=True, seconds=time.monotonic()-start, device=self.device, model=self.key)
        return result


def main():
    engine = None
    for line in sys.stdin:
        try:
            request = json.loads(line)
            with contextlib.redirect_stdout(sys.stderr):
                if engine is None:
                    if len(sys.argv) > 3 and sys.argv[3] == 'fusion':
                        from fusion_engine import FusionEngine
                        engine = FusionEngine(sys.argv[1], sys.argv[4], sys.argv[2])
                    elif len(sys.argv) > 3 and sys.argv[3] == 'qwen':
                        from qwen_engine import QwenEngine
                        engine = QwenEngine(sys.argv[1], sys.argv[2])
                    else:
                        engine = Engine(sys.argv[1], sys.argv[2])
                result = engine.handle(request)
        except Exception as error:
            import traceback
            traceback.print_exc(file=sys.stderr)
            result = {"ok": False, "error": str(error)}
        print(json.dumps(result, ensure_ascii=False), flush=True)

if __name__ == "__main__":
    main()

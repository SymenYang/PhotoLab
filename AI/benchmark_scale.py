"""Synthetic warm-search benchmark; real vector dimensions, no media or model inference."""
import os
os.environ['VECLIB_MAXIMUM_THREADS'] = '2'
os.environ['OPENBLAS_NUM_THREADS'] = '2'
import gc, json, tempfile, time
from pathlib import Path
import numpy as np
from fusion_engine import FusionEngine

results = []
for count in (20000, 100000, 200000):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root/'photolab-model.json').write_text(json.dumps({'revision':'synthetic-test'}))
        engine = FusionEngine(str(root), str(root), str(root/'vectors.sqlite'))
        ids = [f'photo-{i}' for i in range(count)]
        candidates = dict.fromkeys(ids, 'fp')
        rng = np.random.default_rng(42)
        for name, dim in [('siglip',768),('qwen',2048)]:
            worker = engine.engines[name]
            matrix = rng.random((count,dim),dtype=np.float32)
            matrix /= np.linalg.norm(matrix,axis=1,keepdims=True)
            worker.check_index()
            worker._fingerprints = candidates.copy()
            worker._vectors = (ids,['fp']*count,matrix,{id:i for i,id in enumerate(ids)})
        started = time.monotonic()
        reply = engine.handle(dict(command='search',candidates=candidates,reference=ids[0]))
        elapsed = time.monotonic()-started
        assert len(reply['hits']) == count and reply['hits'][0]['id'] == ids[0] and reply['hits'][0]['score'] == 1.
        scores = [h['score'] for h in reply['hits']]
        assert scores == sorted(scores,reverse=True)
        started = time.monotonic(); payload = json.dumps(reply); serialized = time.monotonic()-started
        result = dict(assets=count,warmSearchSeconds=elapsed,serializationSeconds=serialized,payloadBytes=len(payload),vectorBytes=count*(768+2048)*4)
        results.append(result); print(json.dumps(result),flush=True)
        for worker in engine.engines.values(): worker.db.close()
        del matrix, worker, engine, reply, payload, candidates
        gc.collect()
Path('build/reports').mkdir(parents=True, exist_ok=True)
Path('build/reports/scale-ai-benchmark.json').write_text(json.dumps({'method':'Synthetic normalized float32 vectors in RAM, real dimensions; warm local image similarity + complete RRF + JSON encoding. Excludes model inference, disk load and Swift UI.','results':results},indent=2))

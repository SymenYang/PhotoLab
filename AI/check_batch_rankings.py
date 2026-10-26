"""Small ranking-stability check, not a retrieval-accuracy evaluation."""
import json, tempfile
from pathlib import Path
import numpy as np
from benchmark_embedding_batches import samples, embed_batch, ROOT, OUT
from qwen_engine import QwenEngine

with tempfile.TemporaryDirectory(prefix='photolab-batch-rank-') as temp:
    data = samples(); images = [im for _,im in data]
    engine = QwenEngine(str(ROOT/'.ai-model-qwen'),str(Path(temp)/'vectors.sqlite')); engine.load()
    baseline = np.concatenate([embed_batch(engine,'qwen',[im]) for im in images])
    queries = ['海边 悠闲','街道上的汽车','建筑的几何线条','透过玻璃拍摄的倒影','逆光下的人物剪影','画面中有大面积留白的照片']
    texts = np.stack([engine.text_vector(q) for q in queries])
    ref_scores = texts @ baseline.T
    results = []
    for size in [2,4]:
        vectors = np.concatenate([embed_batch(engine,'qwen',images[i:i+size]) for i in range(0,len(images),size)])
        scores = texts @ vectors.T
        rows=[]
        for i,q in enumerate(queries):
            a = np.argsort(-ref_scores[i]); b = np.argsort(-scores[i])
            rows.append({'query':q,'top5_overlap':len(set(a[:5])&set(b[:5]))/5,
                         'same_top1':bool(a[0]==b[0]),'max_score_delta':float(np.max(np.abs(scores[i]-ref_scores[i]))),
                         'single_top5':[data[j][0] for j in a[:5]],'batch_top5':[data[j][0] for j in b[:5]]})
        a = baseline @ baseline.T; b = vectors @ vectors.T
        np.fill_diagonal(a,-2); np.fill_diagonal(b,-2)
        overlap = [len(set(np.argsort(-a[i])[:5])&set(np.argsort(-b[i])[:5]))/5 for i in range(len(images))]
        result={'batch':size,'min_vector_cosine':float(np.sum(baseline*vectors,axis=1).min()),'text_queries':rows,
                'similar_photo_top5_mean_overlap':float(np.mean(overlap)),'similar_photo_top1_agreement':float(np.mean(a.argmax(1)==b.argmax(1)))}
        results.append(result); print(json.dumps(result,ensure_ascii=False),flush=True)
    (OUT/'ranking-stability.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    engine.db.close()

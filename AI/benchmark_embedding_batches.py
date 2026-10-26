"""Offline, temporary-DB throughput experiment. Never writes to the user's indexes."""
import argparse, concurrent.futures, gc, hashlib, json, os, resource, sqlite3, statistics, tempfile, threading, time
from pathlib import Path
from worker import Engine
from qwen_engine import QwenEngine
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/reports/embedding-throughput'

def samples():
    db = sqlite3.connect(f"file:{Path.home()}/Library/Application Support/PhotoLab/catalog.sqlite?mode=ro", uri=True)
    rows = [json.loads(r[0]) for r in db.execute('SELECT data FROM assets')]
    db.close()
    available = []
    for a in sorted(rows, key=lambda a: hashlib.sha256(a['id'].encode()).digest()):
        if a['video']: continue
        f = next((f for f in a['files'] if Path(f['relativePath']).suffix.lower() not in {'.3fr','.arw','.dng'}), a['files'][0])
        path = a.get('identityPaths', {}).get(f['relativePath'], f['relativePath'])
        key = hashlib.sha256(f"{a['id']}|{path}|{f['size']}|{float(f['modified'])}".encode()).hexdigest()
        cached = Path.home() / 'Library/Caches/PhotoLab/Thumbnails' / (key + '.jpg')
        if not cached.exists(): continue
        with Image.open(cached) as im:
            image = im.convert('RGB').rotate(-90 * (a.get('rotation') or 0), expand=True)
            scale = 512 / max(image.size)
            image = image.resize((round(image.width*scale), round(image.height*scale)))
        available.append((a['name'], image))
        if len(available) == 24: break
    if len(available) < 24: raise RuntimeError('Need 24 cached real photos')
    return available

def embed_batch(engine, model, items):
    t = engine.torch
    if model == 'siglip':
        inputs = engine.processor(images=items, return_tensors='pt').to('mps')
        with t.inference_mode():
            features = engine.model.get_image_features(**inputs)
            if not hasattr(features, 'norm'): features = features.pooler_output
    else:
        prompts = [engine.processor.apply_chat_template([
            {'role':'system','content':[{'type':'text','text':"Represent the user's input."}]},
            {'role':'user','content':[{'type':'image','image':im}]}], tokenize=False, add_generation_prompt=True) for im in items]
        inputs = engine.processor(text=prompts, images=items, padding=True, return_tensors='pt').to('mps')
        with t.inference_mode():
            hidden = engine.model(**inputs, use_cache=False).last_hidden_state
            last = inputs['attention_mask'].shape[1]-1-inputs['attention_mask'].flip(1).argmax(1)
            features = hidden[t.arange(len(items), device='mps'), last].float()
    with t.inference_mode():
        return (features / features.norm(dim=-1, keepdim=True).clamp(min=1e-12)).float().cpu().numpy()

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('model', choices=['siglip','qwen']); parser.add_argument('--threads', action='store_true', help='Experimental: Qwen concurrent MPS calls can abort the process'); args = parser.parse_args()
    sample = samples(); images = [x[1] for x in sample]
    with tempfile.TemporaryDirectory(prefix='photolab-batch-') as temp:
        engine = (QwenEngine if args.model == 'qwen' else Engine)(str(ROOT / ('.ai-model-qwen' if args.model == 'qwen' else '.ai-model')), str(Path(temp)/'vectors.sqlite'))
        start = time.perf_counter(); engine.load(); load_seconds = time.perf_counter()-start
        t = engine.torch
        assert engine.device == 'mps', 'This benchmark requires actual Metal GPU acceleration'
        paths = []
        for i, im in enumerate(images):
            path = Path(temp)/f'{i}.png'; im.save(path); paths.append(str(path))
        def batch(items): return embed_batch(engine, args.model, items)
        # Warm every geometry for each configuration; exclude model loading/first compilation.
        modes = ['batch1','batch2','batch4'] + (['batch8'] if args.model == 'siglip' else []) + (['threads2'] if args.threads else [])
        baseline = np.stack([engine.image_vector(path) for path in paths])
        print(json.dumps({'event':'baseline_ready','model':args.model,'load_seconds':load_seconds}), flush=True)
        results = []
        for mode in modes:
            if mode != 'threads2':
                size = int(mode[5:])
                for i in range(0,len(images),size): batch(images[i:i+size])
        def run(mode):
            if mode == 'threads2':
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                    return np.concatenate(list(pool.map(lambda im: batch([im]), images)))
            size = int(mode[5:])
            return np.concatenate([batch(images[i:i+size]) for i in range(0,len(images),size)])
        if args.threads: run('threads2')
        for rep in range(3):
            order = modes if rep == 0 else list(reversed(modes)) if rep == 1 else modes[2:]+modes[:2]
            for mode in order:
                gc.collect(); t.mps.synchronize(); t.mps.empty_cache()
                peak = [0,0]; stop = threading.Event()
                def monitor():
                    while not stop.wait(.01):
                        peak[0] = max(peak[0], t.mps.current_allocated_memory())
                        peak[1] = max(peak[1], t.mps.driver_allocated_memory())
                thread = threading.Thread(target=monitor, daemon=True); thread.start()
                start = time.perf_counter(); cpu = time.process_time()
                vectors = run(mode); t.mps.synchronize()
                seconds = time.perf_counter()-start; cpu = time.process_time()-cpu
                stop.set(); thread.join()
                cosines = np.sum(vectors*baseline, axis=1)
                result = {'mode':mode,'rep':rep,'seconds':seconds,'images_per_second':len(images)/seconds,'cpu_core_equivalent':cpu/seconds,
                          'min_cosine_to_single':float(cosines.min()),'max_abs_vector_delta':float(np.max(np.abs(vectors-baseline))),
                          'sampled_tensor_peak_GiB':peak[0]/1024**3,'sampled_driver_peak_GiB':peak[1]/1024**3,
                          'process_lifetime_peak_RSS_GiB':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1024**3}
                if not np.isfinite(vectors).all() or cosines.min() < .99: raise RuntimeError(f'Embedding drift: {result}')
                results.append(result); print(json.dumps(result), flush=True)
                (OUT/f'{args.model}.json').write_text(json.dumps({'model':args.model,'device':engine.device,'load_seconds':load_seconds,'samples':[(name,im.size) for name,im in sample], 'results':results}, indent=2, ensure_ascii=False))
        engine.db.close()
if __name__ == '__main__': main()

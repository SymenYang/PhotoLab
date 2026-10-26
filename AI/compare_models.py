"""Compare both local indexes on exactly the same photographs; save an offline report."""
import base64, hashlib, html, json, sqlite3, subprocess, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
ROOT = Path(__file__).resolve().parent.parent
DATA = Path.home() / 'Library/Application Support/PhotoLab'
OUT = ROOT / 'build/reports/qwen-comparison'
QUERIES = ['海边 悠闲', '街道上的汽车', '建筑的几何线条', '透过玻璃拍摄的倒影', '逆光下的人物剪影', '画面中有大面积留白的照片']

def worker(backend):
    return subprocess.Popen([sys.executable, '-u', str(ROOT/'AI/worker.py'), str(ROOT/('.ai-model-qwen' if backend == 'qwen' else '.ai-model')), str(DATA/('SemanticSearch/Qwen/vectors.sqlite' if backend == 'qwen' else 'SemanticSearch/vectors.sqlite')), backend], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(OUT/f'{backend}.log','w'), text=True)
def call(p, **req):
    p.stdin.write(json.dumps(req,ensure_ascii=False)+'\n'); p.stdin.flush()
    r=json.loads(p.stdout.readline())
    if not r['ok']: raise RuntimeError(r)
    return r

def thumbnail(a):
    raws={'arw','3fr','fff','dng','cr2','cr3','nef','nrw','raf','orf','rw2','pef','srw'}
    f=next((f for f in a['files'] if Path(f['relativePath']).suffix.lower()[1:] not in raws),a['files'][0])
    key=hashlib.sha256(f"{a['id']}|{f['relativePath']}|{f['size']}|{float(f['modified'])}".encode()).hexdigest()
    path=Path.home()/'Library/Caches/PhotoLab/Thumbnails'/f'{key}.jpg'
    if not path.exists(): return None
    with Image.open(path) as im:
        return im.convert('RGB').rotate(-90*(a.get('rotation') or 0),expand=True)

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    db=sqlite3.connect(f'file:{DATA}/catalog.sqlite?mode=ro',uri=True)
    assets={id:json.loads(raw) for id,raw in db.execute('select id,data from assets')}
    fp={}
    for backend in ['siglip','qwen']:
        p=worker(backend);fp[backend]=call(p,command='status')['fingerprints'];p.stdin.close();p.wait()
    ids={id for id in set(fp['siglip']) & set(fp['qwen']) if fp['siglip'][id] == fp['qwen'][id] and id in assets}
    results={'count':len(ids),'queries':QUERIES,'models':{}}
    for backend in ['siglip','qwen']:
        p=worker(backend)
        results['models'][backend]=[]
        for query in QUERIES:
            r=call(p,command='search',text=query,candidates={id:fp[backend][id] for id in ids})
            for hit in r['hits']: hit['name']=assets[hit['id']]['name']
            results['models'][backend].append(r)
            print(backend,query,r['seconds'],[x['name'] for x in r['hits'][:4]],flush=True)
        p.stdin.close();p.wait()
    (OUT/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    page=['<!doctype html><meta charset="utf-8"><title>PhotoLab 模型对比</title><style>body{background:#131619;color:#eee;font:16px system-ui;margin:32px}img{max-width:100%}section{margin-bottom:48px}small{color:#aaa}</style>',f'<h1>SigLIP 2 / Qwen3-VL 2B</h1><p>同一组 {len(ids)} 张照片；每个模型展示前 6 张。比较排序，分数不可跨模型比较。</p>']
    font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',18)
    for i,query in enumerate(QUERIES):
        board=Image.new('RGB',(1320,520),'#131619');draw=ImageDraw.Draw(board)
        for row,backend in enumerate(['siglip','qwen']):
            r=results['models'][backend][i]
            draw.text((8,row*260+4),f"{backend} | {r['seconds']:.3f}s ({'cold' if i == 0 else 'warm'})",font=font,fill='white')
            for col,hit in enumerate(r['hits'][:6]):
                im=thumbnail(assets[hit['id']])
                if im:
                    im.thumbnail((208,200))
                    board.paste(im,(col*220+(220-im.width)//2,row*260+32+(200-im.height)//2))
                draw.text((col*220+8,row*260+236),hit['name'],font=font,fill='white')
        file=OUT/f'query-{i+1}.jpg';board.save(file,quality=92)
        page.append(f'<section><h2>{html.escape(query)}</h2><img src="{file.name}"></section>')
    page.append('<small>首条查询包含模型加载；这是定性试验，没有人工标注的准确率结论。图片来自本地缓存，未上传。</small>')
    (OUT/'index.html').write_text('\n'.join(page))
if __name__=='__main__':main()

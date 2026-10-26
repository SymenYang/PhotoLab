"""Explicit real-model check; only isolated temporary databases are written."""
import json, os, sys, tempfile
from pathlib import Path
from shared_worker import Runtime
config=json.loads(Path('build/PhotoLab.app/Contents/Resources/AI/config.json').read_text())
os.environ['PHOTOLAB_QWEN_COREML']=config.get('qwenCoreML','')
if len(sys.argv) != 3:
    raise SystemExit('Usage: verify_shared_models.py <art|embedding> <test-image>')
family=sys.argv[1]
with tempfile.TemporaryDirectory(prefix='photolab-shared-check-') as tmp:
    root=Path(tmp);runtime=Runtime(config,family)
    image=str(Path(sys.argv[2]).resolve())
    def send(backend,request):
        db=root/('Qwen/vectors.sqlite' if backend=='qwen' else 'scores.sqlite' if backend=='art' else 'quality.sqlite' if backend=='quality' else 'vectors.sqlite')
        return runtime.handle(dict(backend=backend,database=str(db),request=request))
    if family=='art':
        a=send('art',dict(command='score',path=image))['rawScore'];model=runtime.engines['art'].model
        q=send('quality',dict(command='score',path=image))['rawScore']
        assert runtime.engines['art'].model is model
        a2=send('art',dict(command='score',path=image))['rawScore']
        assert a==a2 and runtime.engines['art'].model is model
        assert send('art',dict(command='status'))['artScores']=={}
        assert send('quality',dict(command='status'))['artScores']=={}
        print('PASS same Q-ReAlign weights across art/quality/art, identical repeated IAA, ephemeral scores absent from both databases',a,q,flush=True)
    else:
        for name in ['siglip','qwen']:
            send(name,dict(command='index',id='image',fingerprint='fp',path=image))
        engines=dict(runtime.engines)
        for name in engines:
            single=send(name,dict(command='search',candidates={'image':'fp'},text='a photograph of a landscape'))
            assert len(single['hits'])==1
        identities={name:(e.model,getattr(e,'coreml',None)) for name,e in engines.items()}
        fusion=send('fusion',dict(command='search',candidates={'image':'fp'},text='a photograph of a landscape'))
        assert fusion['scoreKind']=='fusion'
        for name in engines:
            assert runtime.engines[name] is engines[name]
            assert (engines[name].model,getattr(engines[name],'coreml',None))==identities[name]
        # Force cached-only reference search to prove that load isn't called.
        for e in engines.values():e.load=lambda: (_ for _ in ()).throw(AssertionError('cache-only search loaded model'))
        assert send('fusion',dict(command='search',candidates={'image':'fp'},reference='image'))['hits'][0]['id']=='image'
        print('PASS real SigLIP/Qwen indexing, text queries, fusion shared objects, cached reference search',flush=True)

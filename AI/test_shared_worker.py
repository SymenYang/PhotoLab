import json, sqlite3, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
from shared_worker import Runtime

class SharedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        for name in ['siglip','qwen']:
            (self.root/name).mkdir(); (self.root/name/'photolab-model.json').write_text(json.dumps(dict(revision='test')))
        self.config = dict(model=str(self.root/'siglip'),qwenModel=str(self.root/'qwen'))
        self.now = 0
        self.runtime = Runtime(self.config,'embedding',idle_seconds=180,clock=lambda:self.now)
        self.db = str(self.root/'vectors.sqlite')
    def tearDown(self):
        for engine in self.runtime.engines.values(): engine.db.close()
        self.tmp.cleanup()
    def request(self,backend,req):
        db = str(self.root/'Qwen/vectors.sqlite') if backend=='qwen' else self.db
        return self.runtime.handle(dict(backend=backend,database=db,request=req))
    def seed(self):
        import numpy as np
        for name in ['siglip','qwen']:
            self.request(name,dict(command='status'));e=self.runtime.engines[name]
            for id,v in [('a',[1,0]),('b',[0,1])]:
                e.db.execute('insert into embeddings values(?,?,?,?)',(id,'fp',e.key,np.array(v,dtype=np.float32).tobytes()))
            e.db.commit()
    def test_fusion_reuses_single_models_and_cached_reference_never_loads(self):
        from worker import Engine
        from qwen_engine import QwenEngine
        self.seed(); before=dict(self.runtime.engines)
        with patch.object(Engine,'load',side_effect=AssertionError('unexpected model load')),patch.object(QwenEngine,'load',side_effect=AssertionError('unexpected Qwen load')):
            reply=self.request('fusion',dict(command='search',candidates={'a':'fp','b':'fp'},reference='a'))
            self.assertEqual(reply['scoreKind'],'fusion');self.assertEqual(reply['hits'][0]['id'],'a')
            self.assertEqual(before,self.runtime.engines)
            self.assertTrue(all(e.model is None for e in before.values()))
    def test_startup_preload_loads_both_models_without_photos(self):
        from worker import Engine
        from qwen_engine import QwenEngine
        def load(engine):
            if engine.model is None:
                engine.model = object()
        with patch.object(Engine, 'load', autospec=True, side_effect=load) as siglip, patch.object(QwenEngine, 'load', autospec=True, side_effect=load) as qwen:
            for backend in ['siglip', 'qwen']:
                self.assertTrue(self.request(backend, dict(command='preload'))['ok'])
                self.assertEqual(self.runtime.engines[backend].fingerprints(), {})
            self.assertEqual(siglip.call_count, 1)
            self.assertEqual(qwen.call_count, 1)
            models = {name: e.model for name, e in self.runtime.engines.items()}
            self.now = 10000
            self.runtime.expire()
            self.assertEqual(models, {name: e.model for name, e in self.runtime.engines.items()})

    def test_embedding_models_remain_resident_after_idle(self):
        self.seed(); before = dict(self.runtime.engines)
        self.now = 10000
        self.assertEqual(self.runtime.expire(), [])
        self.assertEqual(self.runtime.engines, before)
        self.assertIsNone(self.runtime.next_expiry())

    def test_art_runtime_still_expires(self):
        self.seed()
        self.runtime.family = 'art'
        self.now = 181
        self.assertEqual(set(self.runtime.expire()), {'siglip', 'qwen'})

    def test_database_switch_preserves_model_and_isolates_index(self):
        self.seed();e=self.runtime.engines['siglip'];model=object();e.model=model
        self.runtime.handle(dict(backend='siglip',database=str(self.root/'other.sqlite'),request=dict(command='status')))
        self.assertIs(e.model,model);self.assertEqual(e.fingerprints(),{})
        self.assertEqual(self.request('siglip',dict(command='status'))['fingerprints'],{'a':'fp','b':'fp'})
    def test_text_query_cache_shared_between_fusion_and_single(self):
        import numpy as np
        from worker import Engine
        from qwen_engine import QwenEngine
        self.seed(); req=dict(command='search',candidates={'a':'fp','b':'fp'},text='lake')
        with patch.object(Engine,'text_vector',return_value=np.array([1,0],dtype=np.float32)) as s,patch.object(QwenEngine,'text_vector',return_value=np.array([1,0],dtype=np.float32)) as q:
            self.request('fusion',req);self.request('siglip',req);self.request('qwen',req)
            self.assertEqual(s.call_count,1);self.assertEqual(q.call_count,1)

if __name__=='__main__':unittest.main()

import tempfile
import unittest
import json
from pathlib import Path
import numpy as np
from fusion_engine import FusionEngine, fuse, ranks

class FusionTests(unittest.TestCase):
    def test_formula_ties_reference_and_scope(self):
        s = [dict(id='b', score=.8), dict(id='a', score=.8), dict(id='c', score=.7)]
        q = [dict(id='c', score=.9), dict(id='b', score=.7), dict(id='a', score=.6)]
        self.assertEqual(ranks(s), dict(a=1.5, b=1.5, c=3))
        h = {h['id']: h for h in fuse(s, q)}
        self.assertAlmostEqual(h['a']['score'], 30.5*(1/61.5+1/63))
        ref = fuse(s, q, 'a')
        self.assertEqual(ref[0]['id'], 'a')
        self.assertEqual(ref[0]['score'], 1.)
        self.assertEqual(ref[0]['siglipScore'], .8)
        self.assertEqual(ref[0]['qwenRank'], 1.)
        self.assertLess(ref[1]['score'], 1.)
        partial = {h['id']: h for h in fuse(s, q[:2])}
        self.assertEqual(set(partial), {'a', 'b', 'c'})
        self.assertNotIn('qwenScore', partial['a'])
        self.assertAlmostEqual(partial['a']['score'], 61 / 61.5)

    def test_scale_invariance_all_results_and_stable_order(self):
        s = [dict(id=str(i), score=float(i)) for i in range(35)]
        q = list(reversed(s))
        a = fuse(s, q)
        b = fuse([dict(id=h['id'], score=h['score']*100+600) for h in s], q)
        self.assertEqual(a[0]['id'], b[0]['id'])
        self.assertEqual([h['score'] for h in a], [h['score'] for h in b])
        self.assertEqual(len(a), 35)
        tied = [dict(id=i, score=1.) for i in ['z','a','m']]
        self.assertEqual([h['id'] for h in fuse(tied, tied)], ['a','m','z'])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root/'photolab-model.json').write_text(json.dumps(dict(revision='test')))
        self.engine = FusionEngine(str(root), str(root), str(root/'vectors.sqlite'))
        self.req = dict(command='search', text='test', candidates=dict(a='fp',b='fp'))
        for engine in self.engine.engines.values():
            for i, v in [('a',[1.,0.]),('b',[0.,1.])]:
                engine.db.execute('INSERT INTO embeddings VALUES(?,?,?,?)', (i,'fp',engine.key,np.array(v,dtype=np.float32).tobytes()))
            engine.db.commit()
            engine.text_vector = lambda text: np.array([1.,0.],dtype=np.float32)

    def tearDown(self):
        for engine in self.engine.engines.values(): engine.db.close()
        self.tmp.cleanup()

    def test_complete_fusion_and_reference(self):
        r = self.engine.handle(self.req)
        self.assertEqual(r['scoreKind'], 'fusion')
        self.assertEqual(len(r['hits']), 2)
        self.assertEqual(self.engine.handle(dict(command='status'))['fingerprints'], self.req['candidates'])
        r = self.engine.handle(dict(self.req, reference='b'))
        self.assertEqual(r['hits'][0]['id'], 'b')
        self.assertEqual(r['hits'][0]['score'], 1.)

    def test_filter_scope_and_cached_text_vector(self):
        calls = []
        for name, engine in self.engine.engines.items():
            engine.text_vector = lambda text, name=name: calls.append(name) or np.array([1.,0.], dtype=np.float32)
        self.engine.handle(self.req)
        result = self.engine.handle(dict(self.req, candidates=dict(b='fp')))
        self.assertEqual([h['id'] for h in result['hits']], ['b'])
        self.assertEqual(result['searched'], 1)
        self.assertEqual(calls, ['siglip', 'qwen'])

    def test_partial_and_disjoint_indexes_use_all_valid_vectors(self):
        self.engine.engines['qwen'].db.execute("UPDATE embeddings SET fingerprint='stale' WHERE id='b'")
        r = self.engine.handle(self.req)
        self.assertEqual(r['scoreKind'], 'fusion')
        hits = {h['id']: h for h in r['hits']}
        self.assertIn('qwenScore', hits['a'])
        self.assertNotIn('qwenScore', hits['b'])
        self.assertEqual(r['searched'], 2)
        self.engine.engines['siglip'].db.execute("UPDATE embeddings SET fingerprint='stale' WHERE id='a'")
        r = self.engine.handle(self.req)
        self.assertEqual({h['id'] for h in r['hits']}, {'a', 'b'})
        self.assertEqual(r['searched'], 2)
        for hit in r['hits']:
            self.assertEqual(sum(key in hit for key in ['siglipScore', 'qwenScore']), 1)
        # A candidate with neither valid embedding is excluded.
        r = self.engine.handle(dict(self.req, candidates=dict(a='fp', b='fp', c='fp')))
        self.assertEqual(r['searched'], 2)

    def test_reference_uses_only_models_with_valid_reference(self):
        self.engine.engines['qwen'].db.execute("UPDATE embeddings SET fingerprint='stale' WHERE id='a'")
        r = self.engine.handle(dict(self.req, reference='a'))
        self.assertEqual(r['scoreKind'], 'cosine')
        self.assertEqual(r['hits'][0]['id'], 'a')
        self.assertEqual(r['searched'], 2)

    def test_no_valid_embeddings_and_empty_scope(self):
        with self.assertRaises(ValueError):
            self.engine.handle(dict(self.req, candidates=dict(a='new', b='new')))
        with self.assertRaises(ValueError):
            self.engine.handle(dict(self.req, candidates={}))

    def test_rule_fusion_keeps_rank_scale_with_one_model(self):
        def fail(text): raise RuntimeError('unavailable')
        self.engine.engines['qwen'].text_vector = fail
        result = self.engine.handle(dict(self.req, rankFusion=True))
        self.assertEqual(result['scoreKind'], 'fusion')
        self.assertEqual(result['hits'][0]['score'], 1.0)
        self.assertAlmostEqual(result['hits'][1]['score'], 61 / 62)
        self.assertIn('unavailable', result['notice'])
        self.assertEqual(self.engine.handle(self.req)['scoreKind'], 'cosine')

    def test_inference_failure_fallback_and_index_resume(self):
        def fail(text): raise RuntimeError('test failure')
        self.engine.engines['qwen'].text_vector = fail
        r = self.engine.handle(self.req)
        self.assertIn('test failure', r['notice'])
        self.assertEqual(r['scoreKind'], 'cosine')
        calls = []
        for name, e in self.engine.engines.items():
            e.image_vector = lambda path, name=name: calls.append(name) or np.array([1.,0.],dtype=np.float32)
        self.engine.engines['qwen'].db.execute("UPDATE embeddings SET fingerprint='stale' WHERE id='a'")
        self.engine.handle(dict(command='index',id='a',fingerprint='fp',path='unused'))
        self.assertEqual(calls,['qwen'])
        self.assertEqual(len(self.engine.handle(dict(command='status'))['fingerprints']), 2)

if __name__ == '__main__': unittest.main()

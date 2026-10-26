import json
import math
import tempfile
import unittest
from pathlib import Path
import numpy as np
from worker import Engine

class SimilarityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'photolab-model.json').write_text(json.dumps({'revision': 'test'}))
        self.engine = Engine(str(self.root), str(self.root / 'vectors.sqlite'))
        self.photos = []

    def tearDown(self):
        self.engine.db.close()
        self.temp.cleanup()

    def add(self, id, degrees=0, capture=100, folder='', day='day', root='root'):
        angle = math.radians(degrees)
        vector = np.array([math.cos(angle), math.sin(angle)], dtype=np.float32)
        self.engine.db.execute('INSERT INTO embeddings VALUES(?,?,?,?)', (id, 'valid', self.engine.key, vector.tobytes()))
        self.engine.db.commit()
        self.photos.append(dict(id=id, fingerprint='valid', capture=capture, folder=folder, day=day, root=root))

    def groups(self, **options):
        return self.engine.handle(dict(command='cluster', photos=self.photos, **options))['groups']

    def test_threshold_changes_invalidate_cached_groups(self):
        self.add('a', 0); self.add('b', 16)
        self.assertEqual(self.groups(), [])
        self.assertEqual(self.groups(threshold=0.90), [['a', 'b']])
        self.assertEqual(self.groups(threshold=1.0), [])
        self.assertEqual(self.groups(threshold=0.90), [['a', 'b']])

    def test_threshold_below_old_limit(self):
        self.add('a', 0); self.add('b', 60)
        self.assertEqual(self.groups(threshold=0.89), [])
        self.assertEqual(self.groups(threshold=0.4), [['a', 'b']])

    def test_negative_threshold_endpoint(self):
        self.add('a', 0); self.add('b', 180)
        self.assertEqual(self.groups(threshold=-1), [['a', 'b']])

    def test_invalid_threshold_is_rejected(self):
        for threshold in [-1.01, 1.01, float('nan')]:
            with self.assertRaises(ValueError):
                self.engine.cluster(dict(photos=[], threshold=threshold))

    def test_complete_link_prevents_transitive_chain(self):
        self.add('a', 0); self.add('b', 8); self.add('c', 16)
        self.assertEqual(self.groups(), [['a', 'b']])

    def test_scope_time_missing_metadata_and_stale_index(self):
        self.add('a'); self.add('b', 1)
        self.add('other-folder', folder='other'); self.add('other-root', root='other')
        self.add('other-day', day='other'); self.add('late', capture=100 + 86401)
        self.add('unknown', capture=None); self.add('stale')
        self.photos[-1]['fingerprint'] = 'changed'
        self.assertEqual(self.groups(), [['a', 'b']])

    def test_cache_restart_and_changed_members(self):
        self.add('a'); self.add('b')
        self.assertEqual(self.groups(), [['a', 'b']])
        self.engine.db.close()
        self.engine = Engine(str(self.root), str(self.root / 'vectors.sqlite'))
        self.assertEqual(self.groups(), [['a', 'b']])
        self.photos.pop()
        self.assertEqual(self.groups(), [])

    def test_new_vector_invalidates_group_cache(self):
        self.add('a'); self.add('b', 90)
        self.assertEqual(self.groups(), [])
        vector = np.array([1., 0.], dtype=np.float32)
        self.engine.db.execute("UPDATE embeddings SET vector=?, fingerprint='new' WHERE id='b'", (vector.tobytes(),))
        self.engine.db.commit()
        self.photos[-1]['fingerprint'] = 'new'
        self.assertEqual(self.groups(), [['a', 'b']])

    def test_24_hour_span_is_measured_from_first_photo(self):
        self.add('a', capture=100)
        self.add('b', capture=100 + 12 * 3600)
        self.add('c', capture=100 + 24 * 3600)
        self.add('d', capture=100 + 24 * 3600 + 1)
        self.assertEqual(self.groups(), [['a', 'b', 'c']])

    def test_same_day_still_required(self):
        self.add('a', capture=100, day='first')
        self.add('b', capture=101, day='next')
        self.assertEqual(self.groups(), [])

    def test_span_and_size_are_bounded(self):
        for i in range(70): self.add(f'{i:03}', capture=100+i/10)
        self.assertEqual([len(g) for g in self.groups()], [64, 6])
        self.assertEqual(self.groups(), self.groups())

if __name__ == '__main__': unittest.main()

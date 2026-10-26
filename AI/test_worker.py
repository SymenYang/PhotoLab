import json
import tempfile
import unittest
from pathlib import Path
import numpy as np
from worker import Engine

class SearchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        (root / "photolab-model.json").write_text(json.dumps({"revision": "test-revision"}))
        self.root = root
        self.engine = Engine(str(root), str(root / "index.sqlite"))
        for id, fp, vector in [("a", "current-a", [1., 0.]), ("b", "old-rotation", [0.9, 0.1]), ("c", "current-c", [0., 1.])]:
            self.engine.db.execute("INSERT INTO embeddings VALUES(?,?,?,?)", (id, fp, self.engine.key, np.array(vector, dtype=np.float32).tobytes()))
        self.engine.db.commit()
        self.engine.text_vector = lambda text: np.array([1., 0.], dtype=np.float32)

    def tearDown(self):
        self.engine.db.close()
        self.temp.cleanup()

    def test_stale_rotation_and_filter_scope_are_excluded(self):
        result = self.engine.handle({"command": "search", "text": "test", "candidates": {"a": "current-a", "b": "new-rotation"}})
        self.assertEqual([h["id"] for h in result["hits"]], ["a"])
        self.assertEqual(result["searched"], 1)

    def test_reference_is_first_with_exact_self_similarity_and_missing_reference_rejected(self):
        result = self.engine.handle({"command": "search", "reference": "a", "candidates": {"a": "current-a", "c": "current-c"}})
        self.assertEqual([h["id"] for h in result["hits"]], ["a", "c"])
        self.assertEqual(result["hits"][0]["score"], 1.0)
        # A tie must not put an earlier database row before the reference.
        self.engine.db.execute("UPDATE embeddings SET vector=? WHERE id='c'", (np.array([1., 0.], dtype=np.float32).tobytes(),))
        tied = self.engine.handle({"command": "search", "reference": "c", "candidates": {"a": "current-a", "c": "current-c"}})
        self.assertEqual([h["id"] for h in tied["hits"]], ["c", "a"])
        self.assertEqual(tied["hits"][0]["score"], 1.0)
        with self.assertRaises(ValueError):
            self.engine.handle({"command": "search", "reference": "b", "candidates": {"a": "current-a"}})

    def test_restart_reuses_only_same_model_revision(self):
        reopened = Engine(str(self.root), str(self.root / "index.sqlite"))
        self.assertEqual(len(reopened.handle({"command": "status"})["fingerprints"]), 3)
        reopened.key += "new-model"
        self.assertEqual(reopened.handle({"command": "status"})["fingerprints"], {})
        reopened.db.close()

    def test_results_are_ranked_not_probabilities(self):
        result = self.engine.handle({"command": "search", "text": "test", "candidates": {"a": "current-a", "c": "current-c"}})
        self.assertEqual([h["id"] for h in result["hits"]], ["a", "c"])
        self.assertEqual(result["hits"][1]["score"], 0.)

    def test_qwen_does_not_reuse_siglip_vectors(self):
        from qwen_engine import QwenEngine
        other = QwenEngine(str(self.root), str(self.root / "index.sqlite"))
        self.assertNotEqual(other.key, self.engine.key)
        self.assertEqual(other.handle({"command": "status"})["fingerprints"], {})
        self.assertEqual(len(self.engine.handle({"command": "status"})["fingerprints"]), 3)
        other.db.close()

    def test_all_results_are_returned_in_similarity_order(self):
        candidates = {}
        for i in range(30):
            id = f"photo-{i}"
            candidates[id] = "valid"
            self.engine.db.execute("INSERT INTO embeddings VALUES(?,?,?,?)", (id, "valid", self.engine.key, np.array([1. - i / 15., 0.], dtype=np.float32).tobytes()))
        self.engine.db.commit()
        result = self.engine.handle({"command": "search", "text": "test", "candidates": candidates})
        self.assertEqual(len(result["hits"]), 30)
        self.assertEqual([h["id"] for h in result["hits"]], [f"photo-{i}" for i in range(30)])
        self.assertLess(result["hits"][-1]["score"], 0)
        self.assertEqual(result["searched"], 30)

    def test_warm_matrix_reuse_and_external_index_invalidation(self):
        request = dict(command='search',text='test',candidates={'a':'current-a','c':'current-c'})
        self.engine.handle(request)
        matrix = self.engine._vectors[2]
        self.engine.handle(request)
        self.assertIs(self.engine._vectors[2],matrix)
        import sqlite3
        other = sqlite3.connect(self.root/'index.sqlite')
        other.execute("UPDATE embeddings SET fingerprint='changed' WHERE id='a'")
        other.commit();other.close()
        result = self.engine.handle(request)
        self.assertEqual([h['id'] for h in result['hits']],['c'])
        self.assertIsNot(self.engine._vectors[2],matrix)
        self.assertEqual(self.engine.handle(dict(command='status'))['fingerprints']['a'],'changed')

if __name__ == "__main__":
    unittest.main()

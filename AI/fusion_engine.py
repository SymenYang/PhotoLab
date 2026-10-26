"""Available-model mean RRF over the union of valid local rankings."""
import time
from pathlib import Path
from worker import Engine
from qwen_engine import QwenEngine


def ranks(hits, reference=None):
    ordered = sorted((h for h in hits if h['id'] != reference), key=lambda h: (-h['score'], h['id']))
    result = {reference: 1.0} if reference else {}
    offset = 2 if reference else 1
    i = 0
    while i < len(ordered):
        j = i + 1
        while j < len(ordered) and ordered[j]['score'] == ordered[i]['score']:
            j += 1
        rank = offset + (i + j - 1) / 2
        for hit in ordered[i:j]:
            result[hit['id']] = rank
        i = j
    return result


def fuse(siglip, qwen, reference=None):
    s = {h['id']: h['score'] for h in siglip}
    q = {h['id']: h['score'] for h in qwen}
    rs, rq = ranks(siglip, reference if reference in s else None), ranks(qwen, reference if reference in q else None)
    hits = []
    for i in s.keys() | q.keys():
        contributions = []
        hit = dict(id=i)
        for scores, ranking, label in [(s, rs, 'siglip'), (q, rq, 'qwen')]:
            if i in scores:
                contributions.append(61 / (60 + ranking[i]))
                hit[label + 'Score'] = scores[i]
                hit[label + 'Rank'] = ranking[i]
        # Missing embeddings are neither a zero score nor grounds for exclusion.
        hit['score'] = sum(contributions) / len(contributions)
        hits.append(hit)
    for hit in hits:
        if hit['id'] == reference:
            hit['score'] = 1.0
    return sorted(hits, key=lambda h: (h['id'] != reference, -h['score'], h['id']))


class FusionEngine:
    def __init__(self, siglip_model, qwen_model, database):
        self.engines, self.errors = {}, {}
        for name, cls, model, db in [('siglip', Engine, siglip_model, database),
                                    ('qwen', QwenEngine, qwen_model, str(Path(database).parent / 'Qwen/vectors.sqlite'))]:
            try:
                self.engines[name] = cls(model, db)
            except Exception as error:
                self.errors[name] = str(error)

    def handle(self, request):
        start = time.monotonic()
        status = {name: engine.handle({'command': 'status'})['fingerprints'] for name, engine in self.engines.items()}
        command = request['command']
        if command == 'status':
            common = {i: fp for i, fp in status.get('siglip', {}).items() if status.get('qwen', {}).get(i) == fp}
            result = dict(fingerprints=common)
        elif command == 'index':
            if len(self.engines) != 2:
                raise ValueError('混合索引需要两个本地模型：' + str(self.errors))
            result = {}
            for name, engine in self.engines.items():
                if status[name].get(request['id']) != request['fingerprint']:
                    result = engine.handle(request)
        elif command == 'search':
            candidates = request['candidates']
            if not candidates:
                raise ValueError('当前范围没有可检索的照片。')
            replies, failures = {}, dict(self.errors)
            for name, fp in status.items():
                valid = {i: v for i, v in candidates.items() if fp.get(i) == v}
                if not valid:
                    continue
                if request.get('reference') and request['reference'] not in valid:
                    continue
                try:
                    replies[name] = self.engines[name].handle(dict(request, candidates=valid))
                except Exception as error:
                    failures[name] = str(error)
            if len(replies) == 2 or (replies and request.get('rankFusion')):
                result = dict(hits=fuse(replies.get('siglip', {}).get('hits', []), replies.get('qwen', {}).get('hits', []), request.get('reference')),
                              searched=len({h['id'] for reply in replies.values() for h in reply['hits']}), scoreKind='fusion', device='本地融合')
                if failures:
                    result['notice'] = '部分模型不可用：' + str(failures)
            elif replies:
                name, result = next(iter(replies.items()))
                result = dict(result, scoreKind='cosine')
                other = 'qwen' if name == 'siglip' else 'siglip'
                label = 'SigLIP 2' if name == 'siglip' else 'Qwen3-VL 2B'
                reason = failures.get(other, '没有可用索引或参考照片向量')
                result['notice'] = f'混合暂不可用（{other}：{reason}）；本次使用 {label}，显示原始相似度。'
            else:
                raise ValueError('当前范围没有可用的检索结果，请建立或更新索引。' + (str(failures) if failures else ''))
        else:
            raise ValueError('Unknown command')
        result.update(ok=True, seconds=time.monotonic() - start)
        return result

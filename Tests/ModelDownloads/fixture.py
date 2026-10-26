"""Synthetic fixtures only. Never imports a real model, image, catalog or AI runtime."""
import hashlib
import io
import json
from pathlib import Path
import tarfile

REVISION = 'a' * 40
LICENSE = 'SIMULATION ONLY. This is synthetic test data, not a legal agreement or model license.\n'
WEIGHTS = bytes(range(256)) * (32768)  # 8 MiB; not valid neural-network weights.
WORKER = '''import json, sys
for line in sys.stdin:
    request = json.loads(line)
    print(json.dumps(dict(ok=True, rawScore=0.42, notice="synthetic inference", fingerprints={})), flush=True)
'''

def populate(resources, endpoint):
    resources.mkdir(parents=True, exist_ok=True)
    (resources / 'licenses').mkdir(exist_ok=True)
    (resources / 'licenses/fixture.txt').write_text(LICENSE)
    model = dict(id='siglip', repo='test/synthetic', revision=REVISION, key='model', size='8 MiB 测试文件',
                 environment='embedding', title='模拟模型 · 不是真实 AI', license='fixture.txt',
                 licenseSHA256=hashlib.sha256(LICENSE.encode()).hexdigest(), licenseURL=endpoint + '/license',
                 notice='模拟测试占位文本，不构成真实模型许可或法律承诺。只连接本机服务器，不访问图库。')
    (resources / 'models.json').write_text(json.dumps([model], ensure_ascii=False))
    (resources / 'config.json').write_text('{}')
    (resources / 'simulation_worker.py').write_text(WORKER)
    for name in ['requirements.lock', 'scoring-requirements.lock']:
        (resources / name).write_text('# synthetic environment; no packages installed\n')
    bootstrap = b'#!/bin/sh\nexec /usr/bin/python3 "$@"\n'
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode='w:gz') as tar:
        info = tarfile.TarInfo('python/bin/python3'); info.mode = 0o755; info.size = len(bootstrap)
        tar.addfile(info, io.BytesIO(bootstrap))
    archive = archive.getvalue()
    (resources / 'simulation.json').write_text(json.dumps(dict(endpoint=endpoint, archiveURL=endpoint + '/python.tar.gz', archiveSHA256=hashlib.sha256(archive).hexdigest())))
    return model, archive

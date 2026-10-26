"""Explicit-consent installer. Only this process accesses the model network.
Pinned revisions, verified blobs, resumable staging and atomic readiness receipts.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import time
import fcntl
import subprocess
import sys
import urllib.request

RESOURCES = Path(__file__).resolve().parent
COMMON_NOTICE = '第三方模型不是 PhotoLab 自有或出售的模型，不因 PhotoLab 的开源许可而获得额外授权；使用与再分发受原权利人协议约束。'
child = None


def stop(signum, frame):
    if child is not None and child.poll() is None:
        child.terminate()
        child.wait()
    raise SystemExit(130)


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    temporary.replace(path)


def digest(path, git=False):
    h = hashlib.sha1() if git else hashlib.sha256()
    if git:
        h.update(f'blob {path.stat().st_size}\0'.encode())
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def download(url, destination, size, checksum, git=False):
    if destination.exists() and destination.stat().st_size == size and digest(destination, git) == checksum:
        return
    partial = destination.with_name(destination.name + '.partial')
    destination.parent.mkdir(parents=True, exist_ok=True)
    offset = partial.stat().st_size if partial.exists() else 0
    if offset >= size:
        if offset == size and digest(partial, git) == checksum:
            partial.replace(destination)
            return
        partial.unlink()
        offset = 0
    request = urllib.request.Request(url, headers={'Range': f'bytes={offset}-'} if offset else {})
    with urllib.request.urlopen(request, timeout=60) as response:
        resumed = offset > 0 and response.status == 206
        if resumed and not response.headers.get('Content-Range', '').startswith(f'bytes {offset}-'):
            raise ValueError('下载服务器返回了错误的续传范围')
        progress_at = 0.0
        received = offset if resumed else 0
        with partial.open('ab' if resumed else 'wb') as output:
            for chunk in iter(lambda: response.read(1024 * 1024), b''):
                output.write(chunk)
                received += len(chunk)
                if time.monotonic() - progress_at >= 1:
                    print(f'{destination.name}: {received / 1e6:.1f} / {size / 1e6:.1f} MB ({received / max(1, size):.0%})', flush=True)
                    progress_at = time.monotonic()
    # A clean EOF can still be a truncated HTTP response. Keep those bytes for
    # Range retry; only a complete-but-invalid (or oversized) file is corruption.
    if partial.stat().st_size < size:
        raise IOError('下载中断，保留临时文件供续传：' + destination.name)
    if partial.stat().st_size != size or digest(partial, git) != checksum:
        partial.unlink(missing_ok=True)
        raise ValueError('文件长度或校验值不匹配：' + destination.name)
    partial.replace(destination)


def run(arguments):
    global child
    child = subprocess.Popen(arguments)
    status = child.wait()
    child = None
    if status:
        raise RuntimeError('安装依赖失败，请检查网络和磁盘空间后重试')


def install(model_id, root, consent_path):
    models = json.loads((RESOURCES / 'models.json').read_text())
    model = next(m for m in models if m['id'] == model_id)
    consent = json.loads(consent_path.read_text())
    for key in ('id', 'revision', 'licenseSHA256'):
        if consent.get(key) != model[key]:
            raise ValueError('必须先确认当前模型版本与许可证')
    if consent.get('accepted') is not True:
        raise ValueError('未同意模型许可')
    license_path = RESOURCES / 'licenses' / model['license']
    if digest(license_path) != model['licenseSHA256']:
        raise ValueError('许可内容已变化，请更新模型清单并重新确认')
    family = model['environment']
    runtime = root / 'runtimes' / family
    python = runtime / 'bin/python3'
    lock = RESOURCES / ('scoring-requirements.lock' if family == 'scoring' else 'requirements.lock')
    lock_hash = digest(lock)
    marker = runtime / 'photolab-ready.json'
    ready = json.loads(marker.read_text()).get('lock') == lock_hash if marker.exists() and python.exists() else False
    if not ready:
        print('正在安装 Python 依赖（首次需要数 GB 空间）…', flush=True)
        if not python.exists():
            run([sys.executable, '-m', 'venv', str(runtime)])
        run([str(python), '-m', 'pip', 'install', '--disable-pip-version-check', '--only-binary=:all:', '-r', str(lock)])
        run([str(python), '-c', 'import torch, transformers, PIL, sentencepiece'])
        atomic_json(marker, {'lock': lock_hash})
    repo, revision = model['repo'], model['revision']
    print('正在读取固定版本文件清单…', flush=True)
    with urllib.request.urlopen(f'https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true', timeout=60) as response:
        metadata = json.load(response)
    if metadata['sha'] != revision:
        raise ValueError('模型版本不匹配')
    target = root / 'models' / model_id / revision
    files = [f for f in metadata['siblings'] if '/' not in f['rfilename'] and (f['rfilename'].endswith(('.json', '.safetensors', '.model', '.txt', '.jinja', '.md')) or f['rfilename'].upper().startswith(('LICENSE', 'NOTICE', 'COPYING')))]
    if not any(f['rfilename'].endswith('.safetensors') for f in files):
        raise ValueError('模型仓库缺少安全权重文件')
    needed = sum(max(0, f.get('lfs', {}).get('size', f.get('size', 0)) - ((target / f['rfilename']).stat().st_size if (target / f['rfilename']).exists() else 0)) for f in files)
    if shutil.disk_usage(root).free < needed + 512 * 1024 * 1024:
        raise RuntimeError(f'磁盘空间不足，模型还需约 {needed / 1e9:.1f} GB，另需保留 512 MB 空间')
    for i, item in enumerate(files):
        name = item['rfilename']
        if name in ('.', '..') or '\\' in name:
            raise ValueError('非法文件名')
        lfs = item.get('lfs')
        checksum = lfs['sha256'] if lfs else item['blobId']
        size = lfs['size'] if lfs else item['size']
        print(f'[{i+1}/{len(files)}] 下载并校验 {name}（{size / 1e6:.1f} MB）…', flush=True)
        download(f'https://huggingface.co/{repo}/resolve/{revision}/{name}', target / name, size, checksum, git=not lfs)
    (target / model['license']).write_bytes(license_path.read_bytes())
    atomic_json(target / 'photolab-model.json', {'model': repo, 'revision': revision})
    if model_id == 'art':
        atomic_json(target.parent / 'model-revision.json', {'repo': repo, 'revision': revision})
    # This receipt is the only publication point; incomplete downloads cannot be loaded.
    atomic_json(target / 'installed.json', dict(consent, files=[f['rfilename'] for f in files]))
    print('安装完成，可以使用该模型。', flush=True)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, stop)
    p = argparse.ArgumentParser()
    p.add_argument('model'); p.add_argument('root', type=Path); p.add_argument('consent', type=Path)
    a = p.parse_args()
    try:
        a.root.mkdir(parents=True, exist_ok=True)
        with (a.root / 'install.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            install(a.model, a.root, a.consent)
    except Exception as error:
        print('安装失败：' + str(error), flush=True)
        sys.exit(1)

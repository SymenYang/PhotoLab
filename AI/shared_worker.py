"""One lazy model instance per model, shared by all app features and catalogs.
The two Python environments use the same protocol and lifecycle rules.
"""
import os
os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1', TOKENIZERS_PARALLELISM='false')
import contextlib, gc, json, select, sqlite3, sys, time
from pathlib import Path

class Runtime:
    def __init__(self, config, family, idle_seconds=180, clock=time.monotonic):
        self.config, self.family, self.idle_seconds, self.clock = config, family, idle_seconds, clock
        self.engines, self.databases, self.used = {}, {}, {}

    def get(self, name, database):
        if database != ':memory:':
            database = str(Path(database).resolve())
            Path(database).parent.mkdir(parents=True, exist_ok=True)
        engine = self.engines.get(name)
        if engine is None:
            if name == 'art':
                from art_worker import Engine
                engine = Engine(self.config['artModel'], database)
            elif name == 'qwen':
                from qwen_engine import QwenEngine
                engine = QwenEngine(self.config['qwenModel'], database)
            elif name == 'siglip':
                from worker import Engine
                engine = Engine(self.config['model'], database)
            else:
                raise ValueError('Unknown model')
            self.engines[name] = engine
            self.databases[name] = database
        elif self.databases[name] != database:
            # Switching catalogs changes storage, never the model/processor.
            connection = sqlite3.connect(database)
            connection.execute('PRAGMA journal_mode=WAL')
            if name == 'art':
                connection.execute('PRAGMA synchronous=FULL')
                connection.execute('CREATE TABLE IF NOT EXISTS scores(id TEXT PRIMARY KEY,fingerprint TEXT,model TEXT,raw REAL,updated REAL)')
            else:
                connection.execute('CREATE TABLE IF NOT EXISTS embeddings (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, model TEXT NOT NULL, vector BLOB NOT NULL)')
                engine._fingerprints = engine._vectors = engine._data_version = None
            engine.db.close(); engine.db = connection
            self.databases[name] = database
        self.used[name] = self.clock()
        return engine

    def handle(self, envelope):
        backend, database, req = envelope['backend'], envelope['database'], envelope['request']
        touched = []
        try:
            if self.family == 'art' and backend in ('art','quality'):
                engine = self.get('art', ':memory:' if req['command'] == 'score' else database)
                touched = ['art']; engine.set_task(backend)
                return dict(ok=True, **engine.request(req))
            if self.family != 'embedding' or backend not in ('siglip','qwen','fusion'):
                raise ValueError('Backend does not belong to this runtime')
            if backend != 'fusion':
                engine = self.get(backend, database); touched = [backend]
                return engine.handle(req)
            from fusion_engine import FusionEngine
            fusion = FusionEngine.__new__(FusionEngine)
            fusion.engines, fusion.errors = {}, {}
            for name, db in [('siglip', database), ('qwen', str(Path(database).parent/'Qwen/vectors.sqlite'))]:
                try:
                    fusion.engines[name] = self.get(name, db); touched.append(name)
                except Exception as error:
                    fusion.errors[name] = str(error)
            return fusion.handle(req)
        finally:
            # Idle time starts after completion, including long in-flight inference.
            for name in touched:
                self.used[name] = self.clock()

    def expire(self):
        if self.family == 'embedding':
            return []
        expired = [name for name, used in self.used.items() if self.clock()-used >= self.idle_seconds]
        for name in expired:
            engine = self.engines.pop(name)
            engine.db.close()
            del engine
            self.used.pop(name); self.databases.pop(name)
            print(json.dumps(dict(event='model_released',model=name)), file=sys.stderr, flush=True)
        if expired:
            gc.collect()
            torch = sys.modules.get('torch')
            if torch is not None and torch.backends.mps.is_available():
                torch.mps.empty_cache()
        return expired

    def next_expiry(self):
        if self.family == 'embedding':
            return None  # Wait for input/EOF; resident models have no idle deadline.
        return max(0.01, min((self.idle_seconds-(self.clock()-v) for v in self.used.values()), default=self.idle_seconds))

def main():
    config = json.loads(Path(sys.argv[1]).read_text())
    os.environ['PHOTOLAB_QWEN_COREML'] = config.get('qwenCoreML','')
    runtime = Runtime(config, sys.argv[2])
    while True:
        runtime.expire()
        if not select.select([sys.stdin], [], [], runtime.next_expiry())[0]:
            continue
        line = sys.stdin.readline()
        if not line: break
        try:
            with contextlib.redirect_stdout(sys.stderr):
                result = runtime.handle(json.loads(line))
        except Exception as error:
            import traceback
            traceback.print_exc(file=sys.stderr)
            result = dict(ok=False,error=str(error))
        print(json.dumps(result, ensure_ascii=False), flush=True)

if __name__ == '__main__':
    main()

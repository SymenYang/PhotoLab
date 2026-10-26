import hashlib
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from fixture import WEIGHTS, REVISION, LICENSE

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self):
        super().__init__(('127.0.0.1', 0), Handler)
        self.mode = 'normal'; self.requests = []; self.archive = b''
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()
    @property
    def endpoint(self): return 'http://127.0.0.1:' + str(self.server_port)
    def close(self): self.shutdown(); self.server_close(); self.thread.join()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        mode = self.server.mode
        self.server.requests.append(dict(path=self.path, range=self.headers.get('Range'), mode=mode))
        if self.path == '/python.tar.gz':
            payload = b"invalid archive" if mode == "bad-bootstrap" else self.server.archive
        elif self.path == '/license': payload = LICENSE.encode()
        elif self.path.startswith('/api/models/'):
            if mode == 'http-error': self.send_error(503); return
            payload = json.dumps(dict(sha=REVISION, siblings=[dict(rfilename='model.safetensors', lfs=dict(size=len(WEIGHTS), sha256=hashlib.sha256(WEIGHTS).hexdigest()))])).encode()
        elif '/resolve/' in self.path:
            payload = WEIGHTS
            if mode == 'corrupt': payload = b'!' + payload[1:]
        else: self.send_error(404); return
        offset = 0; status = 200
        ranged = self.headers.get('Range')
        if ranged and mode != 'ignore-range':
            offset = int(ranged.removeprefix('bytes=').removesuffix('-')); status = 206
        self.send_response(status)
        if status == 206: self.send_header('Content-Range', f'bytes {offset}-{len(payload)-1}/{len(payload)}')
        self.send_header('Content-Length', str(len(payload)-offset)); self.end_headers()
        model_file = '/resolve/' in self.path
        try:
            sent = 0
            for pos in range(offset, len(payload), 65536):
                self.wfile.write(payload[pos:pos+65536]); self.wfile.flush(); sent += 65536
                if model_file and mode == 'drop' and sent >= 2 * 1024 * 1024:
                    self.connection.shutdown(socket.SHUT_RDWR); return
                if model_file and mode == 'slow': time.sleep(0.04)
        except (BrokenPipeError, ConnectionResetError, OSError): pass

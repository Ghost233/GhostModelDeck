"""Loopback-only prototype: fixed publisher algorithms, cancellable HTTP transport."""
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import select
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PIN = '07e13ea49c67f41da795c28abb4590347e745b7a'
# Author assets are shared read-only inputs; imports must not populate their directory.
sys.dont_write_bytecode = True


def verified_author(source, receipt):
    source = Path(source).resolve()
    proof = json.loads(Path(receipt).read_text())
    if proof.get('pin') != PIN or proof.get('all_passed') is not True:
        raise ValueError('publisher verification receipt missing or wrong pin')
    needed = {'decision_config.json', 'config.json', 'tokenizer.json', 'tokenizer_config.json', 'vocab.json', 'merges.txt', 'chat_template.jinja'}
    needed.update(str(p.relative_to(source)) for p in (source / 'startlux_decision').glob('*.py'))
    needed.update({'startlux_decision/__init__.py', 'startlux_decision/model.py', 'startlux_decision/jevfmt.py', 'startlux_decision/gguf_server.py'})
    checked = set()
    for item in proof['checks']:
        name = item['file']
        if name not in needed:
            continue
        data = (source / name).read_bytes()
        kind = item['hash_kind']
        if kind == 'git_blob_sha1':
            digest = hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()
        elif kind == 'sha256':
            digest = hashlib.sha256(data).hexdigest()
        else:
            raise ValueError('unsupported publisher hash')
        if item.get('passed') is not True or len(data) != item['expected_size'] or digest != item['expected_hash']:
            raise ValueError(f'publisher file not verified: {name}')
        checked.add(name)
    if checked != needed:
        raise ValueError(f'publisher files absent from receipt: {needed - checked}')
    # A private import namespace avoids accidentally reusing an earlier package from another directory.
    namespace = '_gmd_verified_startlux'
    existing = sys.modules.get(namespace)
    if existing is not None and Path(existing.__file__).resolve() != source / 'startlux_decision/__init__.py':
        raise ValueError('publisher import namespace already belongs to another directory')
    if existing is None:
        spec = importlib.util.spec_from_file_location(namespace, source / 'startlux_decision/__init__.py', submodule_search_locations=[str(source / 'startlux_decision')])
        package = importlib.util.module_from_spec(spec)
        sys.modules[namespace] = package
        spec.loader.exec_module(package)
    return importlib.import_module(namespace + '.gguf_server')


def make_server(source, receipt, upstream, name, port=0, deadline_seconds=10.0):
    if not 0 < deadline_seconds <= 10:
        raise ValueError('native deadline must be positive and at most ten seconds')
    target = urlsplit(upstream)
    if target.scheme != 'http' or target.hostname != '127.0.0.1' or target.username or target.password or target.path not in ('', '/') or target.query or target.fragment:
        raise ValueError('upstream must be a credential-free loopback HTTP origin')
    author = verified_author(source, receipt)

    class InlineMap:
        # Publisher _logits() is retained; only its I/O scheduling is serialised.
        def map(self, function, jobs):
            return map(function, jobs)

    class Engine(author.GGUFDecision):
        def _letter_logprobs(self, ids, count):
            request = context.current
            targets = self.letters[:count]
            for n in (256, self.vocab):
                request.check()
                body = json.dumps({'prompt': ids, 'n_predict': 1, 'temperature': -1, 'n_probs': n, 'cache_prompt': False})
                connection = http.client.HTTPConnection(target.hostname, target.port, timeout=request.remaining())
                request.attach(connection)
                try:
                    connection.request('POST', '/completion', body, {'Content-Type': 'application/json'})
                    request.attach_socket(connection.sock)
                    response = connection.getresponse()
                    if response.status != 200:
                        raise RuntimeError(f'llama completion HTTP {response.status}')
                    out = json.loads(response.read())
                finally:
                    request.detach(connection)
                    connection.close()
                request.check()
                rows = out.get('completion_probabilities', out.get('probs'))
                got = {t['id']: t['logprob'] for t in rows[0]['top_logprobs']}
                if all(t in got for t in targets):
                    return [got[t] for t in targets]
            raise RuntimeError('option letters missing from llama-server log-probabilities')

    context = threading.local()
    engine = Engine(str(source), upstream, 1)
    engine.pool.shutdown(wait=True)
    engine.pool = InlineMap()

    class Request:
        def __init__(self, client, deadline):
            self.client, self.deadline = client, deadline
            self.cancelled = threading.Event()
            self.finished = threading.Event()
            self.lock = threading.Lock()
            self.connection = None
            self.upstream_socket = None

        def remaining(self):
            return max(0.001, self.deadline - time.monotonic())

        def check(self):
            if self.cancelled.is_set():
                raise InterruptedError('client disconnected or service stopping')
            if time.monotonic() >= self.deadline:
                raise TimeoutError('native ten-second request budget exhausted')

        def attach(self, connection):
            with self.lock:
                self.check()
                self.connection = connection

        def detach(self, connection):
            with self.lock:
                if self.connection is connection:
                    self.connection = None
                    self.upstream_socket = None

        def attach_socket(self, active_socket):
            with self.lock:
                try:
                    self.check()
                except Exception:
                    active_socket.close()
                    raise
                self.upstream_socket = active_socket

        def abort(self):
            self.cancelled.set()
            with self.lock:
                if self.connection is not None:
                    active_socket = self.upstream_socket or self.connection.sock
                    if active_socket is not None:
                        try:
                            active_socket.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
                    self.connection.close()

        def monitor(self):
            while not self.finished.wait(0.01):
                try:
                    readable, _, _ = select.select([self.client], [], [], 0)
                    if readable and self.client.recv(1, socket.MSG_PEEK) == b'':
                        self.abort()
                        return
                    if time.monotonic() >= self.deadline:
                        # Do not mark deadline expiry as disconnect: client receives 504.
                        with self.lock:
                            active_socket = self.upstream_socket or (self.connection.sock if self.connection is not None else None)
                            if active_socket is not None:
                                active_socket.shutdown(socket.SHUT_RDWR)
                        # A socket timeout alone renews with each byte. Interrupt body reads too.
                        self.client.shutdown(socket.SHUT_RD)
                        return
                except OSError:
                    self.abort()
                    return

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            started = time.monotonic()
            if self.path != '/v1/systemone':
                self.send_error(404)
                return
            request = Request(self.connection, started + deadline_seconds)
            with self.server.active_lock:
                if self.server.stopping:
                    self.send_error(503)
                    return
                self.server.active.add(request)
            acquired = False
            watcher = None
            try:
                watcher = threading.Thread(target=request.monitor)
                watcher.start()
                self.connection.settimeout(request.remaining())
                length = int(self.headers['Content-Length'])
                if not 0 < length <= 8 * 1024 * 1024:
                    raise ValueError('invalid content length')
                payload = json.loads(self.rfile.read(length))
                request.check()
                if payload.get('model') != name:
                    self.send_error(404, 'model_not_found')
                    return
                while not acquired:
                    request.check()
                    acquired = self.server.gate.acquire(timeout=min(0.01, request.remaining()))
                request.check()
                context.current = request
                answers, usage = engine.decide(payload['state'], payload['questions'])
                request.check()
                self.reply(200, {'answers': answers, 'usage': usage, 'model': name})
            except Exception as error:
                if not request.cancelled.is_set():
                    code = 504 if time.monotonic() >= request.deadline or isinstance(error, (TimeoutError, socket.timeout)) else 400 if isinstance(error, (ValueError, KeyError)) else 502
                    try:
                        self.reply(code, {'error': str(error)})
                    except OSError:
                        pass
            finally:
                request.finished.set()
                request.abort()
                if watcher is not None:
                    watcher.join()
                if acquired:
                    self.server.gate.release()
                with self.server.active_lock:
                    self.server.active.discard(request)

        def reply(self, status, data):
            body = json.dumps(data).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    class Server(ThreadingHTTPServer):
        daemon_threads = False

        def __init__(self):
            super().__init__(('127.0.0.1', port), Handler)
            self.gate = threading.Semaphore(1)
            self.active_lock = threading.Lock()
            self.active = set()
            self.stopping = False

        def stop(self):
            with self.active_lock:
                self.stopping = True
                active = list(self.active)
            for request in active:
                request.abort()
                try:
                    request.client.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            self.shutdown()
            self.server_close()

    return Server()


if __name__ == '__main__':
    import argparse
    import signal

    parser = argparse.ArgumentParser()
    parser.add_argument('--model-dir', required=True)
    parser.add_argument('--receipt', required=True)
    parser.add_argument('--llama', required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--generation', type=int, default=0)
    args = parser.parse_args()
    stopped = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopped.set())
    signal.signal(signal.SIGINT, lambda *_: stopped.set())
    service = make_server(args.model_dir, args.receipt, args.llama, args.name, args.port)
    serving = threading.Thread(target=service.serve_forever)
    serving.start()
    print(json.dumps({'status': 'ready', 'port': service.server_port, 'model': args.name, 'pin': PIN, 'generation': args.generation}), flush=True)
    try:
        stopped.wait()
    finally:
        service.stop()
        serving.join()

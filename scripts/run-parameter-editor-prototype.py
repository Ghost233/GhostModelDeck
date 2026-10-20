#!/usr/bin/env python3
"""Serve the disposable instance-editor variants; no application data is used."""
import argparse
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
import webbrowser


class PrototypeHandler(BaseHTTPRequestHandler):
    def __init__(self, *args, document, **kwargs):
        self.document = document
        super().__init__(*args, **kwargs)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            self.send_response(302)
            self.send_header("Location", "/instances?variant=A")
            self.end_headers()
            return
        if path != "/instances":
            self.send_error(404)
            return
        body = self.document.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8877)
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    document = Path(__file__).resolve().parents[1] / "lib/parameter_editor_prototype/index.html"
    server = ThreadingHTTPServer(("127.0.0.1", args.port), partial(PrototypeHandler, document=document))
    url = f"http://127.0.0.1:{server.server_port}/instances?variant=A"
    print(f"Disposable parameter editor: {url}", flush=True)
    print("A: category sidebar; B: inspector drawer; C: guided steps. Ctrl+C stops this preview.", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

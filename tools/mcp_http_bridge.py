#!/usr/bin/env python3
"""Exposes `fyke mcp` over minimal Streamable HTTP, for the official conformance
suite, which only speaks HTTP. For testing only: fyke itself opens no port.

Usage: mcp_http_bridge.py <path-to-fyke> [port]
Then:  npx @modelcontextprotocol/conformance server --url http://127.0.0.1:8931/mcp
"""
import http.server, json, os, subprocess, sys, threading

rss, port = os.path.abspath(sys.argv[1]), int(sys.argv[2]) if len(sys.argv) > 2 else 8931
child = subprocess.Popen([rss, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
lock = threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass

    def respond(self, status, body=b"", kind="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        self.respond(405)  # No server-initiated stream.

    def do_DELETE(self):
        self.respond(405)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        try:
            message = json.loads(body)
        except ValueError:
            message = {"id": None}
        with lock:
            child.stdin.write(body.replace(b"\n", b" ") + b"\n"); child.stdin.flush()
            if isinstance(message, dict) and "id" not in message:
                return self.respond(202)
            line = child.stdout.readline()
        self.respond(200, line.strip())

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

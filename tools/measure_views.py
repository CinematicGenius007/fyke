#!/usr/bin/env python3
"""Measure views.list over 100,000 synthetic articles ingested by the daemon.

Usage: python3 tools/measure_views.py ./zig-out/bin/fyke
The temporary FYKE_HOME is removed, and no real subscriptions are contacted.
"""
import http.server
import json
import os
import platform
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time


class Feed(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        host = int(self.path[1:])
        items = ''.join(
            f'<item><guid>{i}</guid><title>Article {i}</title>'
            f'<link>https://host{host}.example/blog/{i}</link>'
            '<description>Synthetic storage engine article.</description></item>'
            for i in range(1000)
        )
        body = f'<rss version="2.0"><channel><title>Fixture</title>{items}</channel></rss>'.encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    binary = os.path.abspath(sys.argv[1])
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Feed)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='fyke-views-', dir='/tmp') as home:
        env = dict(os.environ, FYKE_HOME=home)
        with open(home + '/config.json', 'w') as config:
            json.dump({'auto_poll': False, 'full_text': False}, config)
        subprocess.run([binary, 'status'], env=env, check=True, capture_output=True)
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(120)
        connection.connect(home + '/fyked.sock')
        stream = connection.makefile('rb')

        def call(method, **params):
            request = {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}
            connection.sendall((json.dumps(request) + '\n').encode())
            reply = json.loads(stream.readline())
            if 'error' in reply:
                raise RuntimeError(reply['error'])
            return reply['result']

        try:
            for i in range(100):
                call('feeds.add', url=f'http://127.0.0.1:{server.server_port}/{i}',
                     allow_private_network=True)
            stats = call('stats.get')
            assert stats['entries'] == 100000, stats
            print(platform.platform(), platform.machine(), flush=True)
            print('100 feeds, 100000 entries, all unread; 10 views; milliseconds over socket', flush=True)
            views = [call('views.put', name=f'Host {i}', rule={'host': f'host{i}.example'}) for i in range(10)]
            for mode in ('exact host (1000 matches/view)', 'all articles (100000 matches/view)'):
                if mode.startswith('all'):
                    for view in views:
                        call('views.put', id=view['id'], name=view['name'], rule={}, expected_revision=1)
                samples = []
                for _ in range(21):
                    start = time.perf_counter()
                    result = call('views.list')
                    samples.append((time.perf_counter() - start) * 1000)
                    expected = 1000 if mode.startswith('exact') else 100000
                    assert all(v['total'] == expected and v['unread'] == expected for v in result['items'])
                cold = samples.pop(0)
                print(f'{mode}: first {cold:.2f}, p50 {statistics.median(samples):.2f}, '
                      f'p95 {sorted(samples)[18]:.2f}, max {max(samples):.2f}', flush=True)
        finally:
            stream.close()
            connection.close()
            subprocess.run([binary, 'daemon', 'stop'], env=env, capture_output=True, check=True)
    server.shutdown()


if __name__ == '__main__':
    main()

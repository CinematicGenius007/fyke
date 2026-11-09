#!/usr/bin/env python3
"""The milestone test: many feeds polling in the background.

  scale.py <rss> local <corpus-dir> [count]   real feed files from a local server
  scale.py <rss> real <corpus-dir>            every corpus URL, over the internet

Local mode records concurrency and repeats. Real mode uses default settings, so
each run sends one request to every feed in the corpus: do not run it often.
"""
import functools, http.server, json, os, shutil, socketserver, sqlite3, subprocess, sys, tempfile, threading, time
from xml.sax.saxutils import quoteattr

rss, mode, corpus = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3]
home = tempfile.mkdtemp(prefix="fyke-s-", dir="/tmp")
env = dict(os.environ, FYKE_HOME=home)

def cli(*args):
    return subprocess.run([rss, *args], env=env, capture_output=True, text=True, timeout=120)

def stats():
    return json.loads(cli("status", "--json").stdout)

def daemon_pid():
    return int(subprocess.run(["lsof", "-t", home + "/fyked.lock"], capture_output=True, text=True).stdout.split()[0])

def usage(pid):
    rss_kb, cpu = subprocess.run(["ps", "-o", "rss=,time=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
    minutes, seconds = cpu.split(":")
    return int(rss_kb) / 1024, int(minutes) * 60 + float(seconds)

active = {"now": 0, "peak": 0}
seen = {}
lock = threading.Lock()

class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *args): pass
    def do_GET(self):
        with lock:
            active["now"] += 1; active["peak"] = max(active["peak"], active["now"])
            seen[self.path] = seen.get(self.path, 0) + 1
        try:
            super().do_GET()
        finally:
            with lock: active["now"] -= 1

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 256

def write_opml(urls):
    body = "".join(f"<outline text={quoteattr(str(i))} xmlUrl={quoteattr(u)}/>" for i, u in enumerate(urls))
    path = home + "/feeds.opml"
    open(path, "w").write(f"<opml version='2.0'><body>{body}</body></opml>")
    return path

def wait_idle(limit):
    start = time.time(); peak = 0; pid = daemon_pid()
    while time.time() - start < limit:
        s = stats(); peak = max(peak, usage(pid)[0])
        if s["due"] == 0 and s["in_flight"] == 0: return time.time() - start, peak, s
        time.sleep(0.25)
    return time.time() - start, peak, stats()

def report_db():
    db = sqlite3.connect(home + "/fyke.db")
    print("integrity", db.execute("pragma integrity_check").fetchone()[0])
    print("statuses", db.execute("select coalesce(http_status, 'none'), count(*) from fetch_log group by 1 order by 2 desc limit 8").fetchall())
    print("errors", db.execute("select error, count(*) from fetch_log where error is not null group by 1 order by 2 desc limit 8").fetchall())
    print("slowest fetches, ms", [r[0] for r in db.execute("select duration_ms from fetch_log order by 1 desc limit 5")])
    return db

if mode == "local":
    count = int(sys.argv[4]) if len(sys.argv) > 4 else 1000
    open(home + "/config.json", "w").write('{"per_host": 16}')
    server = Server(("127.0.0.1", 0), functools.partial(Handler, directory=corpus))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    names = sorted(f for f in os.listdir(corpus) if f.endswith(".feed"))
    urls = [f"{base}/{names[i % len(names)]}?copy={i}" for i in range(count)]
    print(cli("import", write_opml(urls), "--allow-private").stdout.strip())
    seconds, peak, s = wait_idle(300)
    print(f"round 1: {seconds:.1f} s, peak RSS {peak:.0f} MB, peak concurrent requests {active['peak']}, {s}")
    print("feeds fetched more than once:", sum(1 for v in seen.values() if v > 1), "of", len(seen))

    t = time.time(); r = cli("feeds", "--json"); print(f"feeds --json: {(time.time() - t) * 1000:.0f} ms, {len(r.stdout) / 1e6:.1f} MB")
    t = time.time(); cli("list", "--limit", "50"); print(f"list: {(time.time() - t) * 1000:.0f} ms")
    t = time.time(); cli("search", "security"); print(f"search: {(time.time() - t) * 1000:.0f} ms")

    active["peak"] = 0
    cli("refresh")
    seconds, peak, s = wait_idle(300)
    print(f"round 2, validators: {seconds:.1f} s, peak RSS {peak:.0f} MB, {s}")
    report_db().close()

    cli("daemon", "stop"); time.sleep(0.3)
    open(home + "/config.json", "w").write('{"per_host": 2}')
    cli("status"); active["peak"] = 0; cli("refresh")
    seconds, _, s = wait_idle(300)
    print(f"per_host 2: {seconds:.1f} s, peak concurrent requests {active['peak']}")
    server_stop = server.shutdown
else:
    urls = [line.rstrip("\n").split("\t")[2] for line in open(os.path.join(corpus, "index.tsv"))]
    print(cli("import", write_opml(urls)).stdout.strip())
    seconds, peak, s = wait_idle(600)
    print(f"real network: {seconds:.1f} s, peak RSS {peak:.0f} MB, {s}")
    report_db().close()
    server_stop = lambda: None

pid = daemon_pid()
time.sleep(5)
_, cpu_before = usage(pid)
time.sleep(30)
memory, cpu_after = usage(pid)
print(f"idle after work: RSS {memory:.0f} MB, CPU {cpu_after - cpu_before:.2f} s over 30 s")
cli("daemon", "stop"); time.sleep(0.2)
os.system(f"du -sh {home}")
server_stop(); shutil.rmtree(home)

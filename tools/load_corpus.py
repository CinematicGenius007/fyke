#!/usr/bin/env python3
"""Pushes the whole corpus through the real binary, then checks what was stored
against what the parser reported.

Usage: load_corpus.py <path-to-rss> <corpus-dir> <dump.jsonl>
"""
import functools, http.server, json, os, shutil, socketserver, sqlite3, subprocess, sys, tempfile, threading, time

rss, corpus, dump = sys.argv[1:4]
rss = os.path.abspath(rss)
home = tempfile.mkdtemp(prefix="rss-load-", dir="/tmp")  # Short, for the socket path limit.
open(home + "/config.json", "w").write('{"auto_poll": false}')
env = dict(os.environ, RSS_HOME=home)

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
server = Server(("127.0.0.1", 0), functools.partial(Quiet, directory=corpus))
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"

expected = {}
for line in open(dump):
    row = json.loads(line); expected[row["name"]] = len(row["entries"])

ok = failed = crashed = 0
start = time.time()
for name in sorted(expected):
    p = subprocess.run([rss, "add", f"{base}/{name}", "--allow-private"], env=env, capture_output=True, text=True, timeout=120)
    if p.returncode < 0: crashed += 1; print("CRASH", name, p.stderr[:300])
    elif p.returncode != 0: failed += 1; print("failed", name, p.stderr.strip()[:90])
    else: ok += 1
seconds = time.time() - start

db = sqlite3.connect(os.path.join(home, "rss.db"))
stored = dict(db.execute("select substr(url, instr(url, '.feed') - 16, 21), (select count(*) from entries e where e.feed_id = f.id) from feeds f"))
short = [(n, expected[n], stored.get(n, 0)) for n in expected if stored.get(n, 0) != expected[n]]
print(f"added {ok}, failed {failed}, crashed {crashed} in {seconds:.1f} s")
print("entries stored", db.execute("select count(*) from entries").fetchone()[0], "expected", sum(expected.values()))
print("feeds where stored differs from parsed:", len(short), short[:8])
print("integrity", db.execute("pragma integrity_check").fetchone()[0])
db.execute("insert into entries_fts(entries_fts) values('integrity-check')")
print("search index ok")
print("no title", db.execute("select count(*) from entries where title is null").fetchone()[0],
      "| empty body", db.execute("select count(*) from entries where content_text = ''").fetchone()[0],
      "| future sort_at", db.execute("select count(*) from entries where sort_at > first_seen_at").fetchone()[0])
print("control chars in titles", db.execute("select count(*) from entries where title glob '*[' || char(1) || '-' || char(31) || ']*'").fetchone()[0])
size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(home) for f in fs)
print(f"data on disk {size / 1e6:.1f} MB")
for query in ("zig", "the", "security vulnerability"):
    t = time.time(); r = subprocess.run([rss, "search", *query.split(), "--json"], env=env, capture_output=True, text=True); print(f"search {query!r}: {len(json.loads(r.stdout)['items'])} in {(time.time() - t) * 1000:.0f} ms incl. process start")
t = time.time(); subprocess.run([rss, "list", "--unread", "--limit", "50"], env=env, capture_output=True); print(f"list: {(time.time() - t) * 1000:.0f} ms incl. process start")
subprocess.run([rss, "daemon", "stop"], env=env, capture_output=True)
server.shutdown(); shutil.rmtree(home)

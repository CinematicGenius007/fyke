#!/usr/bin/env python3
"""Tests the daemon itself: the socket protocol, permissions, tiers, live events,
OPML, recovery from a crash, and background polling.

Usage: e2e_daemon.py <path-to-rss>
"""
import http.server, json, os, shutil, signal, socket, socketserver, sqlite3, stat, subprocess, sys, tempfile, threading, time

RSS = os.path.abspath(sys.argv[1])
home = tempfile.mkdtemp(prefix="rss-d-", dir="/tmp")  # Short, for the socket path limit.
env = dict(os.environ, RSS_HOME=home)
requests = []
posts = {"count": 1}

def feed_body():
    items = "".join(f"<item><title>Post {i}</title><guid>{i}</guid><description>word{i}</description></item>" for i in range(posts["count"]))
    return f'<rss version="2.0"><channel><title>Live</title>{items}</channel></rss>'.encode()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def do_GET(self):
        requests.append(self.path)
        body = feed_body()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.send_header("Connection", "close")
        self.end_headers(); self.wfile.write(body); self.close_connection = True

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
server = Server(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"

def rss(*args, ok=True):
    p = subprocess.run([RSS, *args], env=env, capture_output=True, text=True, timeout=60)
    if ok and p.returncode != 0: raise AssertionError(f"{args}: exit {p.returncode}: {p.stdout} {p.stderr}")
    return p

class Raw:
    """A hand-written client, to send what the CLI never would."""
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX); self.s.settimeout(10); self.s.connect(home + "/rssd.sock"); self.f = self.s.makefile("rb")
    def line(self, text):
        self.s.sendall(text.encode() + b"\n"); return json.loads(self.f.readline())
    def call(self, method, **params):
        return self.line(json.dumps({"jsonrpc": "2.0", "id": 7, "method": method, "params": params}))

passed = 0
def check(name, condition, detail=""):
    global passed
    if not condition:
        print(f"FAIL {name} {detail}"); print(open(home + "/rssd.log").read()[-800:] if os.path.exists(home + "/rssd.log") else ""); sys.exit(1)
    passed += 1; print(f"ok   {name}")

def wait_for(predicate, seconds=10):
    end = time.time() + seconds
    while time.time() < end:
        if predicate(): return True
        time.sleep(0.02)
    return False

open(home + "/config.json", "w").write('{"auto_poll": false}')

# Startup
start = time.time()
out = rss("status").stdout
check("client starts the daemon", "0 feeds" in out, out)
print(f"     cold start including daemon: {(time.time() - start) * 1000:.0f} ms")
check("data directory is owner-only", stat.S_IMODE(os.stat(home).st_mode) == 0o700, oct(os.stat(home).st_mode))
check("socket is owner-only", stat.S_IMODE(os.stat(home + "/rssd.sock").st_mode) == 0o600)
p = subprocess.run([RSS, "daemon"], env=env, capture_output=True, text=True, timeout=10)
check("a second daemon refuses to start", p.returncode == 1 and "AlreadyRunning" in p.stderr, p.stderr)
check("first daemon survives that", rss("status").returncode == 0)

# Protocol
c = Raw()
r = c.line("this is not json")
check("bad JSON gets a parse error", r["error"]["code"] == -32700, r)
r = c.line("[1,2,3]")
check("non-object gets invalid request", r["error"]["code"] == -32600, r)
r = c.call("no.such.method")
check("unknown method", r["error"]["code"] == -32601 and r["id"] == 7, r)
r = c.call("entries.get", id="not a number")
check("wrong parameter type", r["error"]["code"] == -32602, r)
r = c.call("entries.get", id=999)
check("failure carries a stable kind", r["error"]["data"]["kind"] == "NoSuchEntry", r)
r = c.line('{"id":"abc","method":"stats.get"}')
check("id is echoed as given", r["id"] == "abc" and "result" in r, r)
check("connection survives errors", "result" in c.call("stats.get"))
names = [i["name"] for i in c.call("ops.list")["result"]["items"]]
check("ops.list describes the registry", "entries.search" in names and "db.query" in names, names)

big = socket.socket(socket.AF_UNIX); big.settimeout(10); big.connect(home + "/rssd.sock")
try:
    big.sendall(b"x" * (3 << 20) + b"\n")
except OSError:
    pass
try:
    data = big.recv(100)
except OSError:
    data = b""
check("oversized request closes that connection only", data == b"" and "result" in c.call("stats.get"))

# Tiers
t = Raw()
r = t.call("connection.restrict", tier="read")
check("a connection can lower its tier", r["result"]["tier"] == "read", r)
r = t.call("feeds.add", url=base + "/f", allow_private_network=True)
check("read tier cannot subscribe", r["error"]["code"] == -32001, r)
r = t.call("entries.mark", id=1, read=True)
check("read tier cannot annotate", r["error"]["code"] == -32001, r)
r = t.call("daemon.stop")
check("read tier cannot stop the daemon", r["error"]["code"] == -32001, r)
r = t.call("connection.restrict", tier="manage")
check("a tier cannot be raised again", r["error"]["code"] == -32001, r)
check("read tier can read", "result" in t.call("entries.list"))

# SQL
out = json.loads(rss("query", "SELECT count(*) AS n FROM feeds").stdout)
check("query returns rows", out["columns"] == ["n"] and out["rows"] == [[0]], out)
for sql in ("DELETE FROM feeds", "PRAGMA query_only=OFF", "ATTACH '/tmp/x' AS x", "SELECT 1; DROP TABLE feeds"):
    check(f"refused: {sql}", "error" in json.loads(rss("query", sql).stdout))
start = time.time()
out = json.loads(rss("query", "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c) SELECT count(*) FROM c").stdout)
check("runaway query is stopped", "error" in out, out)
print(f"     stopped after {time.time() - start:.2f} s")
check("schema is available", "CREATE TABLE entries" in rss("schema").stdout)

# Live events
rss("add", base + "/live", "--allow-private")
sub = Raw()
r = sub.line('{"id":1,"method":"events.subscribe","params":{"since_seq":0}}')
check("subscribe is acknowledged", r["result"]["subscribed"], r)
first = json.loads(sub.f.readline())
check("history is replayed from since_seq", first["method"] == "event" and first["params"]["type"] == "entry.new", first)
seq = first["params"]["seq"]
posts["count"] = 2
rss("refresh", "1")
sub.s.settimeout(5)
event = json.loads(sub.f.readline())
check("new entries arrive live", event["params"]["type"] == "entry.new" and event["params"]["seq"] > seq, event)

# Full text
state_page = {"robots": "", "article": True}
long_page = "<html><body><nav>NAV-TEXT</nav><article><h1>Full Post</h1>" + "".join(f"<p>Extracted paragraph {i} with plenty of words in it to look like an article.</p>" for i in range(30)) + "</article><footer>FOOT-TEXT</footer></body></html>"
class Pages(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *args): pass
    def do_GET(self):
        requests.append(self.path)
        if self.path == "/feed":
            body = f"""<rss version="2.0"><channel><title>Summaries</title>
<item><title>Full Post</title><guid>f1</guid><link>{page_base}/posts/1</link><pubDate>Fri, 06 Nov 2026 09:30:00 GMT</pubDate><description>Only a summary.</description></item>
<item><title>Blocked</title><guid>f2</guid><link>{page_base}/private/2</link><description>Only a summary.</description></item>
<item><title>Not a page</title><guid>f3</guid><link>{page_base}/file.pdf</link><description>Only a summary.</description></item>
<item><title>Thin</title><guid>f4</guid><link>{page_base}/thin</link><description>Only a summary.</description></item>
</channel></rss>""".encode(); kind = "application/rss+xml"
        elif self.path == "/robots.txt":
            body = b"User-agent: *\nDisallow: /private\n"; kind = "text/plain"
        elif self.path == "/file.pdf":
            body = b"%PDF"; kind = "application/pdf"
        elif self.path == "/thin":
            body = b"<html><body><p>Nothing much.</p></body></html>"; kind = "text/html"
        else:
            body = long_page.encode(); kind = "text/html; charset=utf-8"
        self.send_response(200); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
pages = Server(("127.0.0.1", 0), Pages)
threading.Thread(target=pages.serve_forever, daemon=True).start()
page_base = f"http://127.0.0.1:{pages.server_address[1]}"
out = json.loads(rss("feeds", "--json").stdout)
add = Raw().call("feeds.add", url=page_base + "/feed", allow_private_network=True)
check("summary feed added", add["result"]["new"] == 4, add)

# Choosing a feed before subscribing
class Site(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        host = f"http://127.0.0.1:{self.server.server_address[1]}"
        one = lambda name: f'<rss version="2.0"><channel><title>{name}</title><link>{host}/</link><item><title>{name} post</title><guid>{name}</guid></item></channel></rss>'
        bodies = {
            "/": f'<html><head><link rel="alternate" type="application/rss+xml" href="/all.xml"><link rel="alternate" type="application/rss+xml" href="/science.xml"><link rel="alternate" type="application/rss+xml" href="/broken.xml"></head></html>',
            "/all.xml": one("All"), "/science.xml": one("Science"), "/empty": "<html><body>No feed here</body></html>",
        }
        body = bodies.get(self.path)
        if body is None:
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        data = body.encode(); kind = "application/rss+xml" if self.path.endswith(".xml") else "text/html"
        self.send_response(200); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
site = Server(("127.0.0.1", 0), Site)
threading.Thread(target=site.serve_forever, daemon=True).start()
site_base = f"http://127.0.0.1:{site.server_address[1]}"
feeds_before = len(json.loads(rss("feeds", "--json").stdout)["items"])
r = Raw().call("feeds.preview", url=site_base + "/", allow_private_network=True)
found = r["result"]["items"]
check("preview lists every working feed on a site", [f["title"] for f in found] == ["All", "Science"], r)
check("preview shows latest titles", found[0]["latest"] == ["All post"], found)
check("preview subscribes to nothing", len(json.loads(rss("feeds", "--json").stdout)["items"]) == feeds_before)
r = Raw().call("feeds.preview", url=site_base + "/all.xml", allow_private_network=True)
check("preview of a feed address finds that feed", [f["title"] for f in r["result"]["items"]] == ["All"], r)
r = Raw().call("feeds.preview", url=site_base + "/empty", allow_private_network=True)
check("preview of a site with no feed is empty", r["result"]["items"] == [], r)
r = Raw().call("feeds.preview", url=site_base + "/")
check("preview refuses private addresses by default", "error" in r, r)
t2 = Raw(); t2.call("connection.restrict", tier="annotate")
r = t2.call("feeds.preview", url=site_base + "/", allow_private_network=True)
check("preview needs the manage tier", r["error"]["code"] == -32001, r)
r = Raw().call("feeds.add", url=site_base + "/science.xml", allow_private_network=True, title="My Science", folder="Reading")
added = next(f for f in json.loads(rss("feeds", "--json").stdout)["items"] if f["id"] == r["result"]["id"])
check("add keeps the chosen name", added["title"] == "My Science", added)
folders = Raw().call("folders.list")["result"]["items"]
check("add creates the folder", [f["name"] for f in folders if f["id"] == added["folder_id"]] == ["Reading"], folders)
Raw().call("feeds.remove", id=r["result"]["id"])

# Settings a client can change
r = Raw().call("config.set", full_text=False)
check("config.set answers", r["result"]["ok"] is True, r)
check("config.get reads it back", Raw().call("config.get")["result"]["full_text"] is False)
saved = json.load(open(os.path.join(home, "config.json")))
check("setting is saved, other keys kept", saved["full_text"] is False and len(saved) > 1, saved)
Raw().call("config.set", full_text=True)
t3 = Raw(); t3.call("connection.restrict", tier="annotate")
check("config.set needs the manage tier", t3.call("config.set", full_text=False)["error"]["code"] == -32001)
rows = json.loads(rss("query", "SELECT id, title FROM entries WHERE title IN ('Full Post','Blocked','Not a page','Thin')").stdout)["rows"]
ids = {title: entry for entry, title in rows}
c2 = Raw()
requests.clear()
r = c2.call("entries.fetch_full", id=ids["Full Post"])
check("article is fetched", r["result"]["status"] == "done", r)
check("robots.txt is asked first", requests[:2] == ["/robots.txt", "/posts/1"], requests)
body = c2.call("entries.get", id=ids["Full Post"], format="text")["result"]["body"]
check("the article replaced the summary", "Extracted paragraph 29" in body and "Only a summary" not in body, body[:200])
check("page furniture is gone", "NAV-TEXT" not in body and "FOOT-TEXT" not in body)
check("the repeated title is gone", not body.startswith("Full Post"), body[:60])
check("search finds the article", any(i["id"] == ids["Full Post"] for i in json.loads(rss("search", "Extracted", "--json").stdout)["items"]))
requests.clear()
r = c2.call("entries.fetch_full", id=ids["Blocked"])
check("robots.txt is obeyed", r["result"]["status"] == "skipped" and "/private/2" not in requests, (r, requests))
check("robots.txt is cached", "/robots.txt" not in requests, requests)
check("a PDF is skipped", c2.call("entries.fetch_full", id=ids["Not a page"])["result"]["status"] == "skipped")
check("a page with no article is skipped", c2.call("entries.fetch_full", id=ids["Thin"])["result"]["status"] == "skipped")
body = c2.call("entries.get", id=ids["Thin"], format="text")["result"]["body"]
check("and the summary stays", body == "Only a summary.", body)
for feed_row in json.loads(rss("feeds", "--json").stdout)["items"]:
    if feed_row["title"] == "Summaries": rss("remove", str(feed_row["id"]))
pages.shutdown()

# Clients at once
errors = []
def hammer():
    try:
        h = Raw()
        for _ in range(200):
            if "result" not in h.call("entries.list", limit=5): errors.append("bad")
            if "result" not in h.call("entries.search", query="word1"): errors.append("bad")
    except Exception as e:
        errors.append(repr(e))
threads = [threading.Thread(target=hammer) for _ in range(8)]
[t.start() for t in threads]
for i in range(3, 13):
    posts["count"] = i
    rss("refresh", "1")
[t.join() for t in threads]
check("8 clients read during writes", not errors, errors[:3])
check("all writes landed", json.loads(rss("status", "--json").stdout)["entries"] == 12)

# OPML
opml = f"""<opml version="2.0"><body>
<outline text="Tech"><outline text="Zig"><outline text="A &amp; B" xmlUrl="{base}/a?x=1&amp;y=2" htmlUrl="{base}/"/></outline>
<outline text="Two" xmlUrl="{base}/b"/></outline>
<outline text="Top" xmlUrl="{base}/c"/><outline text="Bad" xmlUrl="ftp://example.com/x"/></body></opml>"""
path = home + "/in.opml"
open(path, "w").write(opml)
out = rss("import", path, "--allow-private").stdout
check("import adds feeds", "3 added, 0 already" in out, out)
out = rss("import", path, "--allow-private").stdout
check("import is repeatable", "0 added, 3 already" in out, out)
exported = rss("export").stdout
open(path + ".out", "w").write(exported)
check("export keeps nesting and escapes", 'text="Zig"' in exported and "a?x=1&amp;y=2" in exported and "<outline text=\"Tech\">" in exported, exported)
home2 = tempfile.mkdtemp(prefix="rss-e-", dir="/tmp")
env2 = dict(os.environ, RSS_HOME=home2)
open(home2 + "/config.json", "w").write('{"auto_poll": false}')
p = subprocess.run([RSS, "import", path + ".out", "--allow-private"], env=env2, capture_output=True, text=True, timeout=30)
check("exported file imports elsewhere", "4 added" in p.stdout, p.stdout + p.stderr)
again = subprocess.run([RSS, "export"], env=env2, capture_output=True, text=True, timeout=30).stdout
check("export, import, export is stable", sorted(again.splitlines()) == sorted(exported.splitlines()), again)
subprocess.run([RSS, "daemon", "stop"], env=env2, capture_output=True, timeout=30); shutil.rmtree(home2)
rss("remove", "2"); rss("remove", "3"); rss("remove", "4")

# Housekeeping
for i in range(13, 40):
    posts["count"] = i
    rss("refresh", "1")
def raw_files():
    return sum(len(files) for _, _, files in os.walk(home + "/raw"))
check("every changed body is saved", raw_files() >= 30, raw_files())
assert "result" in Raw().call("daemon.housekeep")
check("raw bodies are pruned to 20 per feed", raw_files() == 20, raw_files())
posts["count"] = 40
out = rss("refresh", "1").stdout
check("feed still works after pruning", "1 new" in out, out)

# Crash
out = subprocess.run(["lsof", "-t", home + "/rssd.lock"], capture_output=True, text=True).stdout.split()
pid = int(out[0])
os.kill(pid, signal.SIGKILL)
time.sleep(0.2)
check("stale socket remains after kill -9", os.path.exists(home + "/rssd.sock"))
status = json.loads(rss("status", "--json").stdout)
check("next client restarts the daemon and data survives", status["entries"] == 40, status)
check("database intact after kill", sqlite3.connect(home + "/rss.db").execute("pragma integrity_check").fetchone()[0] == "ok")

# Stopping must answer the client every time, which it once raced with exiting.
for _ in range(25):
    rss("status")
    p = rss("daemon", "stop", ok=False)
    if p.returncode != 0: break
check("stop always answers", p.returncode == 0, p.stderr)

# Background polling
check("stop removes the socket", wait_for(lambda: not os.path.exists(home + "/rssd.sock")))
open(home + "/config.json", "w").write('{"auto_poll": true, "min_poll_seconds": 1}')
db = sqlite3.connect(home + "/rss.db"); db.execute("update feeds set next_fetch_at=0, poll_seconds=1"); db.commit(); db.close()
requests.clear()
posts["count"] = 41
rss("status")
check("daemon polls on its own", wait_for(lambda: json.loads(rss("status", "--json").stdout)["entries"] == 41), requests)
count = len(requests)
check("and keeps polling", wait_for(lambda: len(requests) > count + 1, 15), requests)
rss("daemon", "stop")

server.shutdown(); shutil.rmtree(home)
print(f"\n{passed} checks passed")

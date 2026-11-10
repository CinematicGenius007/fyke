#!/usr/bin/env python3
"""Tests the daemon itself: the socket protocol, permissions, tiers, live events,
OPML, recovery from a crash, and background polling.

Usage: e2e_daemon.py <path-to-fyke>
"""
import collections, http.server, json, os, shutil, signal, socket, socketserver, sqlite3, stat, subprocess, sys, tempfile, threading, time

# Unix socket paths are short, so macOS and Linux use /tmp. Windows has no /tmp.
TMP = tempfile.gettempdir() if os.name == "nt" else "/tmp"

RSS = os.path.abspath(sys.argv[1])
home = tempfile.mkdtemp(prefix="fyke-d-", dir=TMP)  # Short, for the socket path limit.
env = dict(os.environ, FYKE_HOME=home)
requests = []
posts = {"count": 1}

malformed = {"on": False, "count": 0}

def feed_body():
    if malformed["on"]:
        malformed["count"] += 1
        return f"not a feed {malformed['count']}".encode()
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
    if ok and p.returncode != 0:
        if os.path.exists(home + "/fyked.log"): print(open(home + "/fyked.log").read()[-2000:])
        raise AssertionError(f"{args}: exit {p.returncode}: {p.stdout} {p.stderr}")
    return p

class WinUnixSocket:
    """Python's socket module has no AF_UNIX on Windows, though the system does, so this
    calls Winsock directly. It offers the few methods the checks use."""
    def __init__(self):
        import ctypes
        from ctypes import wintypes
        self.c = ctypes
        self.w = ctypes.WinDLL("ws2_32", use_last_error=True)
        self.w.socket.restype = ctypes.c_size_t
        self.w.socket.argtypes = [ctypes.c_int] * 3
        self.w.connect.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
        self.w.send.argtypes = [ctypes.c_size_t, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
        self.w.recv.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        self.w.setsockopt.argtypes = [ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self.w.closesocket.argtypes = [ctypes.c_size_t]
        data = ctypes.create_string_buffer(400)
        if self.w.WSAStartup(0x0202, data) != 0: raise OSError("WSAStartup")
        self.h = self.w.socket(1, 1, 0)  # AF_UNIX, SOCK_STREAM
        if self.h == ctypes.c_size_t(-1).value: raise OSError("socket", ctypes.get_last_error())
    def fail(self, what):
        code = self.c.get_last_error()
        if code == 10060: raise TimeoutError(what)
        raise OSError(code, what)
    def settimeout(self, seconds):
        ms = self.c.c_uint32(int(seconds * 1000))
        for opt in (0x1005, 0x1006):  # SO_SNDTIMEO, SO_RCVTIMEO
            self.w.setsockopt(self.h, 0xFFFF, opt, self.c.byref(ms), 4)
    def connect(self, path):
        raw = path.encode()
        addr = self.c.create_string_buffer(2 + 108)
        addr[0:2] = (1).to_bytes(2, "little")
        addr[2:2 + len(raw)] = raw
        if self.w.connect(self.h, addr, 110) != 0: self.fail("connect")
    def sendall(self, data):
        while data:
            n = self.w.send(self.h, data, min(len(data), 1 << 20), 0)
            if n <= 0: self.fail("send")
            data = data[n:]
    def recv(self, n):
        buf = self.c.create_string_buffer(n)
        got = self.w.recv(self.h, buf, n, 0)
        if got < 0: self.fail("recv")
        return buf.raw[:got]
    def makefile(self, mode="r"):
        import io
        sock = self
        class R(io.RawIOBase):
            def readable(self): return True
            def readinto(self, b):
                data = sock.recv(len(b)); b[:len(data)] = data; return len(data)
        raw = io.BufferedReader(R())
        return raw if "b" in mode else io.TextIOWrapper(raw)
    def close(self): self.w.closesocket(self.h)
    def __enter__(self): return self
    def __exit__(self, *a): self.close()

def unix_socket():
    return WinUnixSocket() if os.name == "nt" else socket.socket(socket.AF_UNIX)

class Raw:
    """A hand-written client, to send what the CLI never would."""
    def __init__(self):
        self.s = unix_socket(); self.s.settimeout(10); self.s.connect(home + "/fyked.sock"); self.f = self.s.makefile("rb")
    def line(self, text):
        self.s.sendall(text.encode() + b"\n"); return json.loads(self.f.readline())
    def call(self, method, **params):
        return self.line(json.dumps({"jsonrpc": "2.0", "id": 7, "method": method, "params": params}))

passed = 0
def check(name, condition, detail=""):
    global passed
    if not condition:
        print(f"FAIL {name} {detail}"); print(open(home + "/fyked.log").read()[-800:] if os.path.exists(home + "/fyked.log") else ""); sys.exit(1)
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
if os.name != "nt":
  check("data directory is owner-only", stat.S_IMODE(os.stat(home).st_mode) == 0o700, oct(os.stat(home).st_mode))
  check("socket is owner-only", stat.S_IMODE(os.stat(home + "/fyked.sock").st_mode) == 0o600)
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

big = unix_socket(); big.settimeout(10); big.connect(home + "/fyked.sock")
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
home2 = tempfile.mkdtemp(prefix="fyke-e-", dir=TMP)
env2 = dict(os.environ, FYKE_HOME=home2)
open(home2 + "/config.json", "w").write('{"auto_poll": false}')
p = subprocess.run([RSS, "import", path + ".out", "--allow-private"], env=env2, capture_output=True, text=True, timeout=30)
check("exported file imports elsewhere", "4 added" in p.stdout, p.stdout + p.stderr)
again = subprocess.run([RSS, "export"], env=env2, capture_output=True, text=True, timeout=30).stdout
check("export, import, export is stable", sorted(again.splitlines()) == sorted(exported.splitlines()), again)
subprocess.run([RSS, "daemon", "stop"], env=env2, capture_output=True, timeout=30); shutil.rmtree(home2, ignore_errors=True)
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
if os.name == "nt":
    # No client is running here, so the only fyke.exe is the daemon.
    subprocess.run(["taskkill", "/F", "/IM", "fyke.exe"], capture_output=True)
else:
    out = subprocess.run(["lsof", "-t", home + "/fyked.lock"], capture_output=True, text=True).stdout.split()
    os.kill(int(out[0]), signal.SIGKILL)
time.sleep(0.2)
check("stale socket remains after kill -9", os.path.exists(home + "/fyked.sock"))
status = json.loads(rss("status", "--json").stdout)
check("next client restarts the daemon and data survives", status["entries"] == 40, status)
check("database intact after kill", sqlite3.connect(home + "/fyke.db").execute("pragma integrity_check").fetchone()[0] == "ok")

# Stopping must answer the client every time, which it once raced with exiting.
for _ in range(25):
    rss("status")
    p = rss("daemon", "stop", ok=False)
    if p.returncode != 0: break
check("stop always answers", p.returncode == 0, p.stderr)

# Background polling
check("stop removes the socket", wait_for(lambda: not os.path.exists(home + "/fyked.sock")))
open(home + "/config.json", "w").write('{"auto_poll": true, "min_poll_seconds": 1}')
db = sqlite3.connect(home + "/fyke.db"); db.execute("update feeds set next_fetch_at=0, poll_seconds=1"); db.commit(); db.close()
requests.clear()
posts["count"] = 41
rss("status")
check("daemon polls on its own", wait_for(lambda: json.loads(rss("status", "--json").stdout)["entries"] == 41), requests)
count = len(requests)
check("and keeps polling", wait_for(lambda: len(requests) > count + 1, 15), requests)

entry = json.loads(rss("list", "--json", "--limit", "1").stdout)["items"][0]["id"]
rss("mark", str(entry), "--hide")
check("a hidden entry leaves the list", entry not in [e["id"] for e in json.loads(rss("list", "--json", "--limit", "100").stdout)["items"]])
rss("mark", str(entry), "--unhide")
check("and returns", entry in [e["id"] for e in json.loads(rss("list", "--json", "--limit", "100").stdout)["items"]])

extreme = Raw()
check("an extreme age does not stop the daemon", "result" in extreme.call("entries.list", since_days=2**63 - 1))
check("nor does a negative one", "result" in extreme.call("entries.search", query="word", since_days=-2**63))
check("a huge value cannot be built by a query", "too big" in json.dumps(extreme.call("db.query", sql="SELECT hex(zeroblob(100000000))")))

silent = socket.socket(); silent.bind(("127.0.0.1", 0)); silent.listen(1)
started = time.time()
stalled = rss("add", f"http://127.0.0.1:{silent.getsockname()[1]}/feed", "--allow-private", ok=False)
check("a host that accepts and then stalls ends at the deadline", stalled.returncode != 0 and time.time() - started < 35, time.time() - started)
silent.close()

malformed["on"] = True
feed_id = json.loads(rss("feeds", "--json").stdout)["items"][0]["id"]
for _ in range(25): rss("refresh", str(feed_id))
malformed["on"] = False
extreme.call("daemon.housekeep")
raw_files = sum(len(names) for _, _, names in os.walk(home + "/raw"))
check("bad bodies stay within retention", raw_files <= 40, raw_files)

with open(home + "/fyked.log", "a") as log: log.write("marker\n")
check("a second daemon refuses to start", rss("daemon", "--log", ok=False).returncode != 0)
check("and leaves the running daemon's log alone", "marker" in open(home + "/fyked.log").read())

# Full text after failures: this part needs the background loop
flaky = {"up": False, "hits": collections.Counter()}
ARTICLE = "<html><body><article>" + "".join(f"<p>Recovered paragraph {i} with enough words to count as an article body.</p>" for i in range(40)) + "</article></body></html>"
class Flaky(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        flaky["hits"][self.path] += 1
        host = f"http://127.0.0.1:{self.server.server_address[1]}"
        if self.path == "/feed.xml":
            items = "".join(f"<item><title>{t}</title><guid>{t}</guid><link>{host}{p}</link><description>Short.</description></item>" for t, p in (("Flaky", "/flaky"), ("Gone", "/gone")))
            status, kind, body = 200, "application/rss+xml", f'<rss version="2.0"><channel><title>Flaky</title>{items}</channel></rss>'
        elif self.path == "/flaky" and flaky["up"]: status, kind, body = 200, "text/html", ARTICLE
        elif self.path == "/flaky": status, kind, body = 503, "text/html", ""
        else: status, kind, body = 404, "text/plain", ""
        data = body.encode()
        self.send_response(status); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
flaky_server = Server(("127.0.0.1", 0), Flaky)
threading.Thread(target=flaky_server.serve_forever, daemon=True).start()
flaky_base = f"http://127.0.0.1:{flaky_server.server_address[1]}"

def full_row(title):
    return json.loads(rss("query", f"SELECT full_status, full_attempts, full_retry_at FROM entries WHERE title = '{title}'").stdout)["rows"][0]

rss("add", flaky_base + "/feed.xml", "--allow-private")
check("a 503 is tried", wait_for(lambda: flaky["hits"]["/flaky"] == 1, 15), flaky["hits"])
check("and waits for a retry, with no status", wait_for(lambda: full_row("Flaky")[:2] == [None, 1]), full_row("Flaky"))
check("with a time set", full_row("Flaky")[2] is not None)
later = Raw().call("entries.fetch_full", id=json.loads(rss("query", "SELECT id FROM entries WHERE title = 'Flaky'").stdout)["rows"][0][0])
check("asking by hand reports later", later["result"]["status"] == "later", later)
check("and leaves the entry waiting", full_row("Flaky")[0] is None)

rss("daemon", "stop")
db = sqlite3.connect(home + "/fyke.db"); db.execute("update entries set full_retry_at = 0 where title in ('Flaky', 'Gone')"); db.commit(); db.close()
flaky["up"] = True
rss("status")
check("the retry fetches the article", wait_for(lambda: full_row("Flaky")[0] == "done", 15), full_row("Flaky"))
check("a 404 is final", wait_for(lambda: full_row("Gone")[0] == "failed", 15), full_row("Gone"))
check("and is not tried again", flaky["hits"]["/gone"] == 1, flaky["hits"])

dead = socket.socket(); dead.bind(("127.0.0.1", 0)); dead_port = dead.getsockname()[1]; dead.close()
outage_items = "".join(f"<item><title>Dead {i}</title><guid>d{i}</guid><link>http://127.0.0.1:{dead_port + i}/a</link><description>Short.</description></item>" for i in range(6))
class Outage(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        data = f'<rss version="2.0"><channel><title>Dead links</title>{outage_items}</channel></rss>'.encode()
        self.send_response(200); self.send_header("Content-Type", "application/rss+xml"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
outage_server = Server(("127.0.0.1", 0), Outage)
threading.Thread(target=outage_server.serve_forever, daemon=True).start()
rss("add", f"http://127.0.0.1:{outage_server.server_address[1]}/feed.xml", "--allow-private")
time.sleep(8)
rows = json.loads(rss("query", "SELECT full_status, full_attempts FROM entries WHERE title LIKE 'Dead %'").stdout)["rows"]
check("an outage settles nothing", all(status is None for status, _ in rows), rows)
check("and costs at most the two tries before it was noticed", sum(tries for _, tries in rows) <= 2, rows)

rss("daemon", "stop")

# Folders, feeds and storage
ops_home = tempfile.mkdtemp(prefix="fyke-o-", dir=TMP)
env_ops = dict(os.environ, FYKE_HOME=ops_home)
open(ops_home + "/config.json", "w").write('{"auto_poll": false, "owner_key": 7}')
subprocess.run([RSS, "status"], env=env_ops, capture_output=True, timeout=30)
def op(method, **params):
    with unix_socket() as s:
        s.settimeout(30)
        s.connect(ops_home + "/fyked.sock")
        s.sendall(json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode() + b"\n")
        return json.loads(s.makefile().readline())
def rows(sql):
    return json.loads(subprocess.run([RSS, "query", sql], env=env_ops, capture_output=True, text=True, timeout=30).stdout)["rows"]
top = op("folders.add", name="Top")["result"]["id"]
mid = op("folders.add", name="Mid", parent_id=top)["result"]["id"]
low = op("folders.add", name="Low", parent_id=mid)["result"]["id"]
check("folders.add finds an existing name", op("folders.add", name="Mid", parent_id=top)["result"]["id"] == mid)
check("folders.add refuses an empty name", "error" in op("folders.add", name="  "))
check("folders.add needs a real parent", "error" in op("folders.add", name="X", parent_id=9999))
check("folders.rename works", "result" in op("folders.rename", id=low, name="Deep"))
other = op("folders.add", name="Other", parent_id=mid)["result"]["id"]
check("folders.rename refuses a sibling's name", "error" in op("folders.rename", id=other, name="Deep"))
check("a folder cannot move inside itself", "error" in op("folders.move", id=top, parent_id=low))
check("nor onto itself", "error" in op("folders.move", id=top, parent_id=top))
check("folders.move refuses a name clash at the top level", op("folders.add", name="Deep")["result"]["id"] and "error" in op("folders.move", id=low))
now = int(time.time() * 1000)
old = now - 200 * 24 * 3600 * 1000
db = sqlite3.connect(ops_home + "/fyke.db", timeout=10)
for feed_id, folder in ((1, low), (2, mid), (3, None)):
    db.execute("INSERT INTO feeds (id, url, title, folder_id, created_at) VALUES (?, ?, ?, ?, 0)", (feed_id, f"http://x/{feed_id}", f"F{feed_id}", folder))
    for n, age in enumerate((old, old, now)):
        db.execute("INSERT INTO entries (feed_id, identity, title, first_seen_at, sort_at, content_text, content_blocks_json, content_hash) VALUES (?, ?, ?, ?, ?, ?, '[]', ?)", (feed_id, f"i{n}", f"E{feed_id}-{n}", age, age, "body text " * 40, f"h{n}"))
db.commit(); db.close()
listed = op("entries.list", folder_id=mid)["result"]["items"]
check("entries.list by folder includes folders inside it", sorted({e["feed_id"] for e in listed}) == [1, 2], listed)
check("entries.list by folder leaves others out", all(e["feed_id"] != 3 for e in listed))
check("entries.mark_all covers a folder tree", "result" in op("entries.mark_all", folder_id=low))
feeds = {f["id"]: f for f in op("feeds.list")["result"]["items"]}
check("and only that tree", feeds[1]["unread"] == 0 and feeds[2]["unread"] == 3, feeds)
entry = rows("SELECT id FROM entries WHERE title = 'E1-0'")[0][0]
op("entries.mark", id=entry, starred=True)
check("feeds.list counts stars", op("feeds.list")["result"]["items"][0]["starred"] == 1)
check("feeds.update renames", "result" in op("feeds.update", id=3, title="Mine") and rows("SELECT title_override FROM feeds WHERE id = 3") == [["Mine"]])
op("feeds.update", id=3, title="")
check("an empty title restores the feed's own", rows("SELECT title_override FROM feeds WHERE id = 3") == [[None]])
op("feeds.update", id=3, folder_id=other)
check("feeds.update moves", rows("SELECT folder_id FROM feeds WHERE id = 3") == [[other]])
op("feeds.update", id=3, top_level=True)
check("and moves out", rows("SELECT folder_id FROM feeds WHERE id = 3") == [[None]])
check("feeds.update needs a real folder", "error" in op("feeds.update", id=3, title="Half", folder_id=9999))
check("and a refused call changes nothing", rows("SELECT title_override FROM feeds WHERE id = 3") == [[None]])

check("nothing read today can be trimmed, however old the post", op("storage.free", trim_older_than_days=30)["result"]["trimmed"] == 0)
db = sqlite3.connect(ops_home + "/fyke.db", timeout=10)
db.execute("UPDATE entry_state SET read_at = ?", (old,)); db.commit(); db.close()
use = op("storage.get")["result"]
check("storage.get splits the database", use["articles"]["entries"] == 9 and use["articles"]["text_bytes"] > 0 and use["articles"]["search_bytes"] > 0, use)
check("and counts what can be trimmed, sparing stars", use["articles"]["removable"] == 1, use)
r = op("storage.free", trim_older_than_days=1)["result"]
check("storage.free keeps a 30 day floor and spares stars", r["trimmed"] == 1, r)
check("the starred body stays", rows("SELECT length(content_text) > 0 FROM entries WHERE id = %d" % entry) == [[1]])
check("the trimmed row stays, so a feed cannot bring it back unread", rows("SELECT count(*), max(content_hash) FROM entries WHERE title = 'E1-1'") == [[1, "h1"]])

check("config.set keeps the ui object", "result" in op("config.set", ui={"theme": "dark", "tokens": {"light": {"ground": "#000000"}}}))
saved = json.load(open(ops_home + "/config.json"))
check("and the owner's own keys", saved["owner_key"] == 7 and saved["ui"]["theme"] == "dark", saved)
check("config.get returns it", op("config.get")["result"]["ui"]["tokens"]["light"]["ground"] == "#000000")
text = open(ops_home + "/config.json").read().replace('"dark"', '"terminal"').replace('"full_text"', '"x"')
open(ops_home + "/config.json", "w").write(text.rstrip()[:-1] + ',"full_text": false,"remove_read_after_days": 60}')
got = op("config.get")["result"]
check("a hand edit is seen at once", got["ui"]["theme"] == "terminal" and got["full_text"] is False and got["remove_read_after_days"] == 60, got)
open(ops_home + "/config.json", "w").write(text[:20])
got = op("config.get")["result"]
check("a broken edit is reported", got["config_error"] is not None and got["ui"] is None, got)
check("and config.set will not overwrite it", "error" in op("config.set", full_text=True) and open(ops_home + "/config.json").read() == text[:20])
open(ops_home + "/config.json", "w").write('{"auto_poll": false, "full_text": "yes"}')
check("nor one with a wrong type", "error" in op("config.set", ui={"theme": "dark"}) and "yes" in open(ops_home + "/config.json").read())
open(ops_home + "/config.json", "w").write('{"auto_poll": false}')

saved_config = open(ops_home + "/config.json").read()
open(ops_home + "/config.json", "w").write('{"auto_poll": false, "remove_read_after_days": 9000000000000000}')
op("config.get")
check("a huge retention does not stop housekeeping", "result" in op("daemon.housekeep"))
open(ops_home + "/config.json", "w").write('{"auto_poll": false, "remove_read_after_days": 45}')
op("daemon.housekeep")
check("housekeeping follows the file with no client asking", json.load(open(ops_home + "/config.json"))["remove_read_after_days"] == 45 and op("config.get")["result"]["remove_read_after_days"] == 45)
open(ops_home + "/config.json", "w").write("x" * (2 << 20))
check("an unreadable config.json is reported", "error" in op("config.get"))
open(ops_home + "/config.json", "w").write(saved_config)
check("and leaves config.get working", "result" in op("config.get"))
check("stats.get names the API version", op("stats.get")["result"]["api_version"] >= 2)

twin = op("folders.add", name="Twin", parent_id=mid)["result"]["id"]
inner_twin = op("folders.add", name="Twin", parent_id=twin)["result"]["id"]
check("a child may share the deleted folder's name", "result" in op("folders.remove", id=twin) and rows("SELECT parent_id FROM folders WHERE id = %d" % inner_twin) == [[mid]], rows("SELECT id, parent_id, name FROM folders"))
op("folders.remove", id=inner_twin)

check("deleting a folder hands its contents to the parent", "result" in op("folders.remove", id=mid) and rows("SELECT folder_id FROM feeds WHERE id = 2") == [[top]] and rows("SELECT parent_id FROM folders WHERE id = %d" % low) == [[top]], rows("SELECT id, parent_id, name FROM folders"))
check("its entries stay", rows("SELECT count(*) FROM entries") == [[9]])
check("deleting with contents removes feeds and subfolders", "result" in op("folders.remove", id=top, delete_contents=True) and rows("SELECT id FROM feeds") == [[3]], rows("SELECT id FROM feeds"))
check("and their entries", rows("SELECT count(*) FROM entries") == [[3]])
check("and the folders inside", rows("SELECT count(*) FROM folders WHERE id IN (%d, %d)" % (top, low)) == [[0]])
subprocess.run([RSS, "daemon", "stop"], env=env_ops, capture_output=True, timeout=30); shutil.rmtree(ops_home, ignore_errors=True)

# A hand edit that breaks config.json
broken = tempfile.mkdtemp(prefix="fyke-c-", dir=TMP)
env_broken = dict(os.environ, FYKE_HOME=broken)
open(broken + "/config.json", "w").write('{"auto_poll": false,')
p = subprocess.run([RSS, "status"], env=env_broken, capture_output=True, text=True, timeout=30)
check("a broken config.json does not stop the daemon", p.returncode == 0, p.stdout + p.stderr)
with unix_socket() as s:
    s.connect(broken + "/fyked.sock")
    s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"config.get"}\n')
    reply = json.loads(s.makefile().readline())
check("config.get reports the problem", reply["result"]["config_error"] is not None, reply)
check("and the file stays for the owner to fix", open(broken + "/config.json").read() == '{"auto_poll": false,')
subprocess.run([RSS, "daemon", "stop"], env=env_broken, capture_output=True, timeout=30); shutil.rmtree(broken, ignore_errors=True)

# The legacy-folder moves use symlinks, flock and HOME, and `data move` is not on Windows yet.
if os.name != "nt":
    # Moving data out of the legacy location, with its daemon still running
    user = tempfile.mkdtemp(prefix="fyke-m-", dir=TMP)
    legacy = user + "/.rss_"
    os.makedirs(legacy)
    open(legacy + "/config.json", "w").write('{"auto_poll": false}')
    env_old = dict(os.environ, FYKE_HOME=legacy)
    subprocess.run([RSS, "status"], env=env_old, capture_output=True, timeout=30)
    env_new = {k: v for k, v in os.environ.items() if k != "FYKE_HOME"}
    env_new["HOME"] = user
    p = subprocess.run([RSS, "status"], env=env_new, capture_output=True, text=True, timeout=30)
    check("a client reaches the running daemon after the move", p.returncode == 0, p.stdout + p.stderr)
    check("the data moved", os.path.isfile(user + "/.fyke/fyke.db") and not os.path.islink(user + "/.fyke"))
    check("a link stays at the old path", os.path.islink(legacy) and os.path.realpath(legacy) == os.path.realpath(user + "/.fyke"))
    subprocess.run([RSS, "daemon", "stop"], env=env_new, capture_output=True, timeout=30)
    p = subprocess.run([RSS, "status"], env=env_old, capture_output=True, text=True, timeout=30)
    check("the link can start a daemon, as a launch agent would", p.returncode == 0 and os.path.exists(user + "/.fyke/fyked.sock"), p.stdout + p.stderr)
    subprocess.run([RSS, "daemon", "stop"], env=env_old, capture_output=True, timeout=30)
    p = subprocess.run([RSS, "status"], env=env_new, capture_output=True, text=True, timeout=30)
    check("a new daemon starts at the new path", p.returncode == 0 and os.path.exists(user + "/.fyke/fyked.sock"), p.stdout + p.stderr)
    subprocess.run([RSS, "daemon", "stop"], env=env_new, capture_output=True, timeout=30)

    # Both locations already hold data
    user2 = tempfile.mkdtemp(prefix="fyke-m-", dir=TMP)
    os.makedirs(user2 + "/.rss_"); os.makedirs(user2 + "/.fyke")
    open(user2 + "/.rss_/keep", "w").write("old")
    open(user2 + "/.fyke/config.json", "w").write('{"auto_poll": false}')
    env_both = dict(env_new, HOME=user2)
    p = subprocess.run([RSS, "status"], env=env_both, capture_output=True, text=True, timeout=30)
    check("with data in both, the old folder is left alone", p.returncode == 0 and os.path.isfile(user2 + "/.rss_/keep") and not os.path.islink(user2 + "/.rss_"), p.stdout + p.stderr)
    subprocess.run([RSS, "daemon", "stop"], env=env_both, capture_output=True, timeout=30)

    # A link at ~/.fyke to data that could not move, as a second volume leaves it
    user3 = tempfile.mkdtemp(prefix="fyke-m-", dir=TMP)
    os.makedirs(user3 + "/.rss_")
    open(user3 + "/.rss_/config.json", "w").write('{"auto_poll": false}')
    os.symlink(user3 + "/.rss_", user3 + "/.fyke")
    env_link = dict(env_new, HOME=user3)
    p = subprocess.run([RSS, "status"], env=env_link, capture_output=True, text=True, timeout=30)
    check("a link at the new path is left in place", p.returncode == 0 and os.path.islink(user3 + "/.fyke") and os.path.isfile(user3 + "/.rss_/fyke.db"), p.stdout + p.stderr)
    subprocess.run([RSS, "daemon", "stop"], env=env_link, capture_output=True, timeout=30)
    shutil.rmtree(user, ignore_errors=True); shutil.rmtree(user2, ignore_errors=True); shutil.rmtree(user3, ignore_errors=True)

    # Data written by a build from before the name: old file names, found at ~/.rss_
    import fcntl
    def earlier_build_data(folder):
        """A data folder as an earlier build left it: one feed, with the old file names."""
        os.makedirs(folder)
        open(folder + "/config.json", "w").write('{"auto_poll": false}')
        env_b = dict(os.environ, FYKE_HOME=folder)
        subprocess.run([RSS, "add", f"http://127.0.0.1:{server.server_address[1]}/feed.xml", "--allow-private"], env=env_b, capture_output=True, timeout=30)
        subprocess.run([RSS, "daemon", "stop"], env=env_b, capture_output=True, timeout=30)
        time.sleep(0.3)
        for new, old in (("fyke.db", "rss.db"), ("fyke.db-wal", "rss.db-wal"), ("fyke.db-shm", "rss.db-shm"), ("fyked.lock", "rssd.lock"), ("fyked.log", "rssd.log")):
            if os.path.exists(f"{folder}/{new}"): os.rename(f"{folder}/{new}", f"{folder}/{old}")
        if os.path.exists(folder + "/fyked.sock"): os.remove(folder + "/fyked.sock")

    user4 = tempfile.mkdtemp(prefix="fyke-m-", dir=TMP)
    earlier_build_data(user4 + "/.rss_")
    env_old_names = dict(env_new, HOME=user4)
    p = subprocess.run([RSS, "feeds", "--json"], env=env_old_names, capture_output=True, text=True, timeout=30)
    check("data under the old file names is still there after the rename", p.returncode == 0 and len(json.loads(p.stdout)["items"]) == 1, p.stdout + p.stderr)
    check("the database was renamed, not copied", os.path.isfile(user4 + "/.fyke/fyke.db") and not os.path.exists(user4 + "/.fyke/rss.db"))
    check("the earlier daemon's leftovers are gone", not any(os.path.exists(user4 + "/.fyke/" + n) for n in ("rssd.sock", "rssd.lock", "rssd.log")))
    subprocess.run([RSS, "daemon", "stop"], env=env_old_names, capture_output=True, timeout=30)

    # A link at ~/.rss_ that `data move` made: the data stays where the person put it
    user5 = tempfile.mkdtemp(prefix="fyke-m-", dir=TMP)
    elsewhere = tempfile.mkdtemp(prefix="fyke-e-", dir=TMP) + "/data"
    earlier_build_data(elsewhere)
    os.symlink(elsewhere, user5 + "/.rss_")
    env_linked = dict(env_new, HOME=user5)
    p = subprocess.run([RSS, "feeds", "--json"], env=env_linked, capture_output=True, text=True, timeout=30)
    check("a moved folder reached through the old link is migrated", p.returncode == 0 and len(json.loads(p.stdout)["items"]) == 1, p.stdout + p.stderr)
    check("the new anchor links to the same folder", os.path.islink(user5 + "/.fyke") and os.path.realpath(user5 + "/.fyke") == os.path.realpath(elsewhere))
    check("the old anchor still reaches it", os.path.islink(user5 + "/.rss_") and os.path.realpath(user5 + "/.rss_") == os.path.realpath(elsewhere))
    check("the data did not move", os.path.isfile(elsewhere + "/fyke.db"))
    subprocess.run([RSS, "daemon", "stop"], env=env_linked, capture_output=True, timeout=30)

    # An earlier daemon still running: its lock is held, so nothing is renamed beneath it
    user6 = tempfile.mkdtemp(prefix="fyke-m-", dir=TMP)
    earlier_build_data(user6 + "/.rss_")
    held = open(user6 + "/.rss_/rssd.lock", "a+"); fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
    p = subprocess.run([RSS, "feeds", "--json"], env=dict(env_new, HOME=user6), capture_output=True, text=True, timeout=30)
    check("a running earlier daemon stops the migration with a clear error", p.returncode != 0 and "EarlierDaemonRunning" in p.stderr, p.stdout + p.stderr)
    check("and nothing was renamed", os.path.isfile(user6 + "/.fyke/rss.db") and not os.path.exists(user6 + "/.fyke/fyke.db"))
    held.close()
    p = subprocess.run([RSS, "feeds", "--json"], env=dict(env_new, HOME=user6), capture_output=True, text=True, timeout=30)
    check("once it has stopped, the migration goes through", p.returncode == 0 and len(json.loads(p.stdout)["items"]) == 1, p.stdout + p.stderr)
    subprocess.run([RSS, "daemon", "stop"], env=dict(env_new, HOME=user6), capture_output=True, timeout=30)
    for d in (user4, user5, os.path.dirname(elsewhere), user6): shutil.rmtree(d, ignore_errors=True)

    # fyke data move, with a throwaway HOME so that nothing real is touched
    mv_home = tempfile.mkdtemp(prefix="fyke-v-", dir=TMP)
    env_mv = {k: v for k, v in os.environ.items() if k != "FYKE_HOME"}
    env_mv["HOME"] = mv_home
    def move(*args):
        return subprocess.run([RSS, "data", "move", *args], env=env_mv, capture_output=True, text=True, timeout=90)
    def status():
        return subprocess.run([RSS, "status"], env=env_mv, capture_output=True, text=True, timeout=30)
    def feed_list():
        return subprocess.run([RSS, "feeds", "--json"], env=env_mv, capture_output=True, text=True, timeout=30).stdout
    os.makedirs(mv_home + "/.fyke")
    open(mv_home + "/.fyke/config.json", "w").write('{"auto_poll": false}')
    status()
    subprocess.run([RSS, "add", f"http://127.0.0.1:{server.server_address[1]}/feed.xml", "--allow-private"], env=env_mv, capture_output=True, timeout=30)
    feeds_before = feed_list()
    check("data move refuses a relative path", "NotAbsolute" in move("relative").stderr)
    os.makedirs(mv_home + "/full"); open(mv_home + "/full/x", "w").write("x")
    check("and a folder that holds other files", "TargetNotEmpty" in move(mv_home + "/full").stderr)
    check("and one inside the data folder", "InsideCurrentFolder" in move(mv_home + "/.fyke/inner").stderr)
    check("and one whose parent is missing", "ParentMissing" in move(mv_home + "/nope/data").stderr)
    p = move(mv_home + "/first")
    check("data move reports its stages", p.returncode == 0 and p.stdout.split() == ["stopping", "moving", "linking", "starting", "done"], p.stdout + p.stderr)
    check("~/.fyke links to the new folder", os.path.islink(mv_home + "/.fyke") and os.path.realpath(mv_home + "/.fyke") == os.path.realpath(mv_home + "/first"))
    check("the daemon runs on the moved data", feed_list() == feeds_before)
    long_name = mv_home + "/" + "very-long-folder-name-" * 6 + "data"
    p = move(long_name)
    check("a link makes a long folder name work, which a socket path could not hold", p.returncode == 0 and status().returncode == 0 and len(long_name) > 110, p.stderr + status().stderr)
    check("moving again leaves nothing behind", not os.path.exists(mv_home + "/first"))
    os.makedirs(mv_home + "/real_parent"); os.symlink(mv_home + "/real_parent", mv_home + "/link_parent")
    p = move(mv_home + "/link_parent/data")
    check("a parent reached through a link is fine", p.returncode == 0 and status().returncode == 0, p.stdout + p.stderr)
    p = move(mv_home + "/.fyke")
    check("moving back to ~/.fyke makes it a folder again", p.returncode == 0 and os.path.isdir(mv_home + "/.fyke") and not os.path.islink(mv_home + "/.fyke"), p.stdout + p.stderr)
    check("and the data is intact", feed_list() == feeds_before)
    subprocess.run([RSS, "daemon", "stop"], env=env_mv, capture_output=True, timeout=30)
    os.rename(mv_home + "/.fyke", mv_home + "/rel_data"); os.symlink("rel_data", mv_home + "/.fyke")
    p = move(mv_home + "/after_rel")
    check("a link written relative to its folder is understood", p.returncode == 0 and os.path.realpath(mv_home + "/.fyke") == os.path.realpath(mv_home + "/after_rel") and not os.path.exists(mv_home + "/rel_data") and feed_list() == feeds_before, p.stdout + p.stderr)
    check("moving back again", move(mv_home + "/.fyke").returncode == 0 and os.path.isdir(mv_home + "/.fyke") and not os.path.islink(mv_home + "/.fyke"))
    check("moving onto the same folder is refused", "SameFolder" in move(mv_home + "/.fyke").stderr)
    check("FYKE_HOME blocks a move", "HomeIsOverridden" in subprocess.run([RSS, "data", "move", mv_home + "/x"], env=dict(env_mv, FYKE_HOME=mv_home + "/.fyke"), capture_output=True, text=True, timeout=30).stderr)

    if sys.platform == "darwin":
        # A real second volume, because a rename cannot cross one
        image = mv_home + "/v.dmg"; mount = mv_home + "/vol"
        subprocess.run(["hdiutil", "create", "-quiet", "-size", "40m", "-fs", "APFS", "-volname", "rssv", image], check=True)
        os.makedirs(mount); subprocess.run(["hdiutil", "attach", "-quiet", "-mountpoint", mount, image], check=True)
        try:
            os.makedirs(mv_home + "/.fyke.old"); open(mv_home + "/.fyke.old/mine", "w").write("keep")
            os.symlink("config.json", mv_home + "/.fyke/kept-link")
            p = move(mount + "/data")
            check("a move to another volume copies and verifies", p.returncode == 0 and "verifying" in p.stdout.split(), p.stdout + p.stderr)
            check("the data is there, behind a link, and the old folder is gone", os.path.islink(mv_home + "/.fyke") and os.path.realpath(mv_home + "/.fyke").startswith(os.path.realpath(mount)) and not os.path.exists(mv_home + "/.fyke.old1"))
            check("the daemon runs there", feed_list() == feeds_before)
            check("a link inside the data folder survives the copy", os.path.islink(mount + "/data/kept-link") and os.readlink(mount + "/data/kept-link") == "config.json")
            check("a leftover .fyke.old is not touched or reused", open(mv_home + "/.fyke.old/mine").read() == "keep" and not os.path.exists(mv_home + "/.fyke.old1"))
            p = move(mv_home + "/.fyke")
            check("and back again from another volume", p.returncode == 0 and os.path.isdir(mv_home + "/.fyke") and not os.path.islink(mv_home + "/.fyke") and not os.path.exists(mount + "/data"), p.stdout + p.stderr)
            check("with its data intact, links included", feed_list() == feeds_before and os.path.islink(mv_home + "/.fyke/kept-link"))
        finally:
            subprocess.run([RSS, "daemon", "stop"], env=env_mv, capture_output=True, timeout=30)
            subprocess.run(["hdiutil", "detach", "-quiet", "-force", mount], capture_output=True)
    subprocess.run([RSS, "daemon", "stop"], env=env_mv, capture_output=True, timeout=30)
    shutil.rmtree(mv_home, ignore_errors=True)

if os.name == "nt":
    # fyke data move: a pointer file in %LOCALAPPDATA%\\Fyke names the folder that holds the data.
    wm = tempfile.mkdtemp(prefix="fyke-w-", dir=TMP)
    anchor = wm + "\\Fyke"
    env_w = dict(os.environ, LOCALAPPDATA=wm); env_w.pop("FYKE_HOME", None)
    def wfyke(*args):
        return subprocess.run([RSS, *args], env=env_w, capture_output=True, text=True, timeout=60)
    def wstatus():
        return json.loads(wfyke("status", "--json").stdout)
    wfyke("add", f"http://127.0.0.1:{server.server_address[1]}/feed.xml", "--allow-private")
    check("the default folder holds the data", os.path.exists(anchor + "\\fyke.db"), os.listdir(wm))
    feeds = wstatus()["entries"]
    check("a feed was added", feeds > 0, feeds)
    check("the move refuses a relative folder", wfyke("data", "move", "elsewhere").returncode != 0)
    check("nor the folder it is in", wfyke("data", "move", anchor).returncode != 0)
    target = wm + "\\moved"
    p = wfyke("data", "move", target)
    check("data move succeeds", p.returncode == 0 and "done" in p.stdout, p.stdout + p.stderr)
    check("the data is in the new folder", os.path.exists(target + "\\fyke.db"))
    check("the default folder keeps only the pointer", os.listdir(anchor) == ["location"], os.listdir(anchor))
    check("the pointer names the folder", open(anchor + "\\location").read().strip().lower() == target.lower())
    check("clients find the data there", wstatus()["entries"] == feeds, wstatus())
    check("and the daemon runs from there", os.path.exists(target + "\\fyked.sock"))
    blocked = wm + "\\blocked"; os.makedirs(blocked); open(blocked + "\\x", "w").write("x")
    check("a folder with files in it is refused", wfyke("data", "move", blocked).returncode != 0)
    check("and nothing changed", wstatus()["entries"] == feeds)
    p = wfyke("data", "move", anchor)
    check("moving back succeeds", p.returncode == 0 and "done" in p.stdout, p.stdout + p.stderr)
    check("the data is in the default folder again", os.path.exists(anchor + "\\fyke.db") and not os.path.exists(anchor + "\\location"), os.listdir(anchor))
    check("the other folder is gone", not os.path.exists(target))
    check("and the data is intact", wstatus()["entries"] == feeds)
    wfyke("daemon", "stop")
    shutil.rmtree(wm, ignore_errors=True)

server.shutdown(); shutil.rmtree(home, ignore_errors=True)
print(f"\n{passed} checks passed")

#!/usr/bin/env python3
"""End-to-end test of the fyke binary against a local HTTP server that records
every request it receives.

Usage: e2e.py <path-to-fyke>
"""
import gzip, http.server, json, os, shutil, socketserver, sqlite3, subprocess, sys, tempfile, threading, time

# Unix socket paths are short, so macOS and Linux use /tmp. Windows has no /tmp.
TMP = tempfile.gettempdir() if os.name == "nt" else "/tmp"

RSS = sys.argv[1]
home = tempfile.mkdtemp(prefix="fyke-e2e-", dir=TMP)  # Short, for the socket path limit.
env = dict(os.environ, FYKE_HOME=home)
# Tests decide when fetches happen, so background polling stays off.
open(os.path.join(home, "config.json"), "w").write('{"auto_poll": false}')
requests = []
state = {"body_version": 1}

def feed(version=1):
    second = "<item><title>Second</title><guid>2</guid><description>new</description></item>" if version >= 2 else ""
    edited = "edited body" if version >= 3 else "<p>Hello <b>world</b>, see <a href='/rel'>this</a></p><script>evil()</script>"
    return f"""<?xml version="1.0"?><rss version="2.0"><channel><title>Test &amp; Feed</title><link>http://x/</link>
    <item><title>First\x1b[2J</title><guid>1</guid><link>/posts/1</link><pubDate>Fri, 06 Nov 2026 09:30:00 GMT</pubDate>
    <description><![CDATA[{edited}]]></description></item>{second}</channel></rss>""".encode()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def send(self, status, body=b"", headers=()):
        self.send_response(status)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body))); self.send_header("Connection", "close")
        self.end_headers(); self.wfile.write(body); self.close_connection = True
    def do_GET(self):
        requests.append({"path": self.path, "inm": self.headers.get("If-None-Match"), "ims": self.headers.get("If-Modified-Since"),
                         "ua": self.headers.get("User-Agent"), "ae": self.headers.get("Accept-Encoding")})
        p = self.path
        if p == "/feed" and state.get("hide_feed"): return self.send(404)
        if p == "/feed":
            etag = f'"v{state["body_version"]}"'
            if self.headers.get("If-None-Match") == etag:
                return self.send(304, b"", [("ETag", etag), ("Content-Encoding", "gzip")])
            return self.send(200, feed(state["body_version"]), [("ETag", etag), ("Last-Modified", "Fri, 06 Nov 2026 09:00:00 GMT"), ("Content-Type", "application/rss+xml")])
        if p == "/noetag": return self.send(200, feed(1))
        if p == "/gz": return self.send(200, gzip.compress(feed(1)), [("Content-Encoding", "gzip")])
        if p == "/moved": return self.send(301, b"", [("Location", "/newhome")])
        if p == "/newhome": return self.send(200, feed(1))
        if p == "/temp": return self.send(302, b"", [("Location", "/noetag")])
        if p == "/gone": return self.send(410)
        if p == "/slow-down": return self.send(503, b"", [("Retry-After", "7200")])
        if p == "/bomb": return self.send(200, gzip.compress(b"<rss>" + b"a" * (64 * 1024 * 1024)), [("Content-Encoding", "gzip")])
        if p == "/loop": return self.send(302, b"", [("Location", "/loop")])
        if p == "/site": return self.send(200, b'<html><head><link rel="alternate" type="application/rss+xml" href="/noetag"></head></html>', [("Content-Type", "text/html")])
        if p.startswith("/plainsite"): return self.send(200, b"<html><body>no feed here</body></html>")
        if p == "/garbage": return self.send(200, b"\x00\x01\x02 not xml at all")
        self.send(404)

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
server = Server(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"

def rss(*args, ok=True):
    p = subprocess.run([RSS, *args], env=env, capture_output=True, text=True, timeout=60)
    if ok and p.returncode != 0: raise AssertionError(f"{args}: exit {p.returncode}: {p.stdout} {p.stderr}")
    return p

def db():
    c = sqlite3.connect(os.path.join(home, "fyke.db")); c.row_factory = sqlite3.Row; return c

passed = 0
def check(name, condition, detail=""):
    global passed
    if not condition:
        print(f"FAIL {name} {detail}"); sys.exit(1)
    passed += 1; print(f"ok   {name}")

# SSRF
p = rss("add", base + "/feed", ok=False)
check("private address refused by default", p.returncode == 1 and "PrivateAddress" in p.stderr, p.stderr)
check("refused before any request was sent", len(requests) == 0, requests)
p = rss("add", "http://localhost:%d/feed" % server.server_address[1], ok=False)
check("hostname resolving to loopback refused", "PrivateAddress" in p.stderr and len(requests) == 0, p.stderr)
p = rss("add", "file:///etc/passwd", ok=False)
check("file URL refused", p.returncode == 1)

# First fetch and the content pipeline
rss("add", base + "/feed", "--allow-private")
r = requests[-1]
check("sends our user agent", r["ua"].startswith("fyke/"), r)
check("asks for gzip", "gzip" in (r["ae"] or ""), r)
c = db()
f = c.execute("select * from feeds").fetchone()
check("feed row stored", f["title"] == "Test & Feed" and f["format"] == "rss20" and f["etag"] == '"v1"', dict(f))
e = c.execute("select * from entries").fetchone()
check("escape sequence removed from title", e["title"] == "First[2J", repr(e["title"]))
check("relative link resolved", e["url"] == base + "/posts/1", e["url"])
check("script gone from blocks", "evil" not in e["content_blocks_json"] and "evil" not in e["content_text"])
check("relative link in body resolved", base + "/rel" in e["content_blocks_json"])
check("date stored", e["published_at"] == 1793957400000)
raw = c.execute("select raw_sha256 from fetch_log where raw_sha256 not null").fetchone()[0]
path = os.path.join(home, "raw", raw[:2], raw + ".gz")
check("raw body saved and readable", gzip.open(path).read() == feed(1))

# The milestone test: second poll sends validators and gets 304
out = rss("refresh", "1").stdout
r = requests[-1]
check("second poll sends If-None-Match", r["inm"] == '"v1"', r)
check("second poll sends If-Modified-Since", r["ims"] == "Fri, 06 Nov 2026 09:00:00 GMT", r)
check("304 reported", "not modified" in out, out)
check("304 with gzip header does not crash", db().execute("select http_status from fetch_log order by id desc limit 1").fetchone()[0] == 304)

# New and edited entries, and read state
entry_id = json.loads(rss("list", "--json").stdout)["items"][0]["id"]
rss("mark", str(entry_id), "--read", "--star")
state["body_version"] = 2
out = rss("refresh", "1").stdout
check("new entry found", "1 new, 0 updated" in out, out)
state["body_version"] = 3
out = rss("refresh", "1").stdout
check("edit detected, not duplicated", "0 new, 1 updated" in out, out)
shown = json.loads(rss("show", str(entry_id), "--json", "--format", "text").stdout)
check("read state survives edit", shown["read"] and shown["starred"], shown)
check("edit is visible", shown["body"] == "edited body", shown)
check("output is marked untrusted", shown["trust"] == "untrusted-feed-content")
check("revision bumped", db().execute("select revision from entries where id=?", (entry_id,)).fetchone()[0] == 2)

# Listing, search, formats
listed = json.loads(rss("list", "--limit", "1", "--json").stdout)
check("next_cursor given when a page is full", listed["next_cursor"] is not None, listed)
second = json.loads(rss("list", "--limit", "1", "--before", listed["next_cursor"], "--json").stdout)
check("cursor reaches the next page", second["items"][0]["id"] != listed["items"][0]["id"])
check("unread filter", len(json.loads(rss("list", "--unread", "--json").stdout)["items"]) == 1)
check("search finds body text", len(json.loads(rss("search", "edited", "--json").stdout)["items"]) == 1)
check("search survives bad syntax", rss("search", '"(AND', "--json").returncode == 0)

# Validators ignored by the server
rss("add", base + "/noetag", "--allow-private")
out = rss("refresh", "2").stdout
check("identical body without validators is skipped", "unchanged" in out, out)

# gzip, redirects
rss("add", base + "/gz", "--allow-private")
check("gzip body parsed", db().execute("select count(*) from entries where feed_id=3").fetchone()[0] == 1)
rss("add", base + "/moved", "--allow-private")
check("subscribes at the final URL", db().execute("select url from feeds where id=4").fetchone()[0] == base + "/newhome")
# Permanent move of an existing subscription
c = db(); c.execute("update feeds set url=? where id=4", (base + "/moved",)); c.commit(); c.close()
rss("refresh", "4")
check("301 updates stored URL", db().execute("select url from feeds where id=4").fetchone()[0] == base + "/newhome")
c = db(); c.execute("update feeds set url=? where id=4", (base + "/temp",)); c.commit(); c.close()
rss("refresh", "4")
check("302 keeps stored URL", db().execute("select url from feeds where id=4").fetchone()[0] == base + "/temp")

# Failures
c = db(); c.execute("insert into feeds(url,allow_private_network,created_at) values(?,1,0)", (base + "/gone",)); c.commit()
gone = c.execute("select id from feeds where url like '%/gone'").fetchone()[0]; c.close()
out = rss("refresh", str(gone)).stdout
check("410 stops polling", "gone" in out and db().execute("select status from feeds where id=?", (gone,)).fetchone()[0] == "gone", out)

c = db(); c.execute("insert into feeds(url,allow_private_network,created_at) values(?,1,0)", (base + "/slow-down",)); c.commit()
slow = c.execute("select id from feeds where url like '%/slow-down'").fetchone()[0]; c.close()
rss("refresh", str(slow))
r = db().execute("select next_fetch_at, last_fetch_at, error_count, last_error from feeds where id=?", (slow,)).fetchone()
check("Retry-After honored", r["next_fetch_at"] - r["last_fetch_at"] >= 7200_000, dict(r))
check("failure recorded", r["error_count"] == 1 and r["last_error"] == "HTTP 503", dict(r))

c = db(); c.execute("insert into feeds(url,allow_private_network,created_at) values(?,1,0)", (base + "/bomb",)); c.commit()
bomb = c.execute("select id from feeds where url like '%/bomb'").fetchone()[0]; c.close()
out = rss("refresh", str(bomb)).stdout
check("gzip bomb stopped at the size limit", "failed" in out, out)

c = db(); c.execute("insert into feeds(url,allow_private_network,created_at) values(?,1,0)", (base + "/loop",)); c.commit()
loop = c.execute("select id from feeds where url like '%/loop'").fetchone()[0]; c.close()
out = rss("refresh", str(loop)).stdout
check("redirect loop stops", "failed" in out and "TooManyRedirects" in out, out)

# Discovery
before = db().execute("select count(*) from feeds").fetchone()[0]
rss("add", base + "/site", "--allow-private")
check("page with a feed link resolves to the feed", db().execute("select count(*) from feeds").fetchone()[0] == before)
requests.clear()
rss("add", base + "/plainsite/", "--allow-private")
check("falls back to well-known paths", any(r["path"] == "/feed" for r in requests), requests)
state["hide_feed"] = True
p = rss("add", base + "/plainsite", "--allow-private", ok=False)
check("page with no feed fails clearly", "NoFeedFound" in p.stderr, p.stderr)
p = rss("add", base + "/garbage", "--allow-private", ok=False)
check("garbage is not subscribed", p.returncode == 1)
state["hide_feed"] = False

# Refresh all continues past failures
before = len(requests)
out = rss("refresh").stdout
check("refresh all is queued", "queued" in out, out)
for _ in range(500):
    status = json.loads(rss("status", "--json").stdout)
    if status["due"] == 0 and status["in_flight"] == 0: break
    time.sleep(0.02)
check("queued feeds all finish", status["due"] == 0 and status["in_flight"] == 0, status)
check("refresh all reaches every active feed", len(requests) - before >= 5, len(requests) - before)

check("usage error exit code", rss("nonsense", ok=False).returncode == 2)
check("missing entry exit code", rss("show", "99999", ok=False).returncode == 1)
check("database integrity", db().execute("pragma integrity_check").fetchone()[0] == "ok")
check("search index integrity", db().execute("insert into entries_fts(entries_fts) values('integrity-check')") is not None)

rss("daemon", "stop")
server.shutdown(); shutil.rmtree(home)
print(f"\n{passed} checks passed")

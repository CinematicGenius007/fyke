#!/usr/bin/env python3
"""Tests `rss tui` in a real pseudo-terminal, reading the screen through pyte, an
independent terminal emulator.

Usage: e2e_tui.py <path-to-rss> [monkey-keys]     (needs: pip install pyte)
"""
import fcntl, http.server, json, os, pty, random, re, select, shutil, signal, socketserver, sqlite3, stat, struct
import subprocess, sys, tempfile, termios, threading, time
import pyte

RSS = os.path.abspath(sys.argv[1])
MONKEY = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
home = tempfile.mkdtemp(prefix="rss-t-", dir="/tmp")
shim = tempfile.mkdtemp(prefix="rss-b-", dir="/tmp")
opened = shim + "/opened.txt"
env = dict(os.environ, RSS_HOME=home, TERM="xterm-256color", PATH=shim + ":" + os.environ["PATH"])
open(home + "/config.json", "w").write('{"auto_poll": false}')
# A stand-in for the browser opener, which records exactly what it was given.
for name in ("open", "xdg-open"):
    path = f"{shim}/{name}"
    open(path, "w").write(f'#!/bin/sh\nprintf "%s\\n" "$#:$1" >> {opened}\n')
    os.chmod(path, 0o755)

state = {"live": 0}
def main_feed():
    live = "".join(f"<item><title>Live story {i}</title><guid>live{i}</guid></item>" for i in range(state["live"]))
    return f"""<rss version="2.0"><channel><title>Main Feed</title><link>http://x/</link>{live}
<item><title>First article</title><guid>a1</guid><link>https://example.com/one?a=1&amp;b=$(touch /tmp/pwned)</link>
<pubDate>Fri, 06 Nov 2026 09:30:00 GMT</pubDate><dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">Sam</dc:creator>
<description><![CDATA[<h2>Section</h2><p>Hello <b>world</b> with a <a href="https://example.com/link">link</a>.</p>
<ul><li>first point</li><li>second point</li></ul><blockquote>wise words</blockquote><pre><code>let x = 1;</code></pre>
{"".join(f"<p>Paragraph number {i} with enough words to wrap across the width of the reader pane.</p>" for i in range(60))}
<p>THE-LAST-LINE</p>]]></description></item>
<item><title>中文标题测试 😀 emoji</title><guid>a2</guid><description>宽字符内容</description></item>
<item><title>Evil&#27;]0;HACKED&#7; title&#27;[2J</title><guid>a3</guid><description><![CDATA[<p>body&#27;]0;HACKED&#7;</p>]]></description></item>
</channel></rss>""".encode()

def many_feed():
    return ('<rss version="2.0"><channel><title>Big Feed</title>' +
            "".join(f"<item><title>Item {i:04d}</title><guid>{i}</guid></item>" for i in range(350)) + "</channel></rss>").encode()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *args): pass
    def do_GET(self):
        body = main_feed() if self.path == "/main" else many_feed()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
server = Server(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"

def rss(*args):
    return subprocess.run([RSS, *args], env=env, capture_output=True, text=True, timeout=60)

passed = 0
def check(name, condition, detail=""):
    global passed
    if not condition:
        print(f"FAIL {name} {str(detail)[:900]}")
        rss("daemon", "stop"); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(shim, ignore_errors=True); sys.exit(1)
    passed += 1; print(f"ok   {name}")

class Term:
    def __init__(self, columns=130, rows=40):
        self.master, self.slave = pty.openpty()
        self.resize(columns, rows, signal_child=False)
        self.saved = termios.tcgetattr(self.slave)
        self.raw = b""
        self.p = subprocess.Popen([RSS, "tui"], env=env, stdin=self.slave, stdout=self.slave, stderr=self.slave, start_new_session=True)
    def resize(self, columns, rows, signal_child=True):
        self.columns, self.rows = columns, rows
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        self.screen = pyte.Screen(columns, rows)
        self.stream = pyte.ByteStream(self.screen)
        if hasattr(self, "raw"): self.stream.feed(self.raw_since_reset())
        if signal_child: self.p.send_signal(signal.SIGWINCH)
    def raw_since_reset(self):
        return b""
    def pump(self, seconds=0.12):
        end = time.time() + seconds
        got = b""
        while True:
            wait = max(end - time.time(), 0)
            r, _, _ = select.select([self.master], [], [], wait)
            if r:
                try: data = os.read(self.master, 1 << 16)
                except OSError: break
                got += data; self.raw += data; self.stream.feed(data)
                end = max(end, time.time() + 0.03)
            elif time.time() >= end: break
        return got
    def keys(self, text, seconds=0.12):
        os.write(self.master, text if isinstance(text, bytes) else text.encode())
        return self.pump(seconds)
    def drain_write(self, data):
        """Writes while reading, since the program blocks if nobody reads its output."""
        os.set_blocking(self.master, False)
        try:
            while data:
                r, w, _ = select.select([self.master], [self.master], [], 5)
                if not r and not w: raise TimeoutError("the program stopped reading and writing")
                if r:
                    self.raw = (self.raw + os.read(self.master, 1 << 16))[-4096:]  # Too much for pyte to parse.
                if w:
                    try:
                        data = data[os.write(self.master, data[:256]):]
                    except BlockingIOError:
                        pass
        finally:
            os.set_blocking(self.master, True)

    def text(self):
        return "\n".join(self.screen.display)
    def wait_for(self, needle, seconds=6):
        end = time.time() + seconds
        while time.time() < end:
            self.pump(0.05)
            if needle in self.text(): return True
        return False
    def finish(self):
        for _ in range(100):
            self.pump(0.05)
            if self.p.poll() is not None: break
        code = self.p.wait(timeout=1); self.pump(0.05)
        after = termios.tcgetattr(self.slave)
        # The kernel itself sets PENDIN when a terminal returns to canonical mode.
        after[3] &= ~0x20000000
        os.close(self.master); os.close(self.slave)
        return code, after

rss("add", base + "/main", "--allow-private")
rss("add", base + "/many", "--allow-private")

# Startup and layout
start = time.time()
t = Term()
check("first paint", t.wait_for("Main Feed"), t.text())
print(f"     to first paint, through pyte: {(time.time() - start) * 1000:.0f} ms")
check("uses the alternate screen", b"\x1b[?1049h" in t.raw)
check("lists the entries", "Item 0349" in t.text() and "Feeds" in t.text(), t.text())

def separators(term):
    columns = set()
    # Buffer positions are true columns. The strings in `display` shrink by one
    # for each wide character.
    for y in range(term.rows - 1):
        columns.add(tuple(x for x in range(term.columns) if term.screen.buffer[y][x].data == "│"))
    return columns

# Reading
t.keys("j"); t.keys("j", 0.3)
check("moving selects a feed", "First article" in t.text() and "Main Feed" in t.screen.display[0], t.text())
check("wide text does not shift the pane borders", "中文标题测试" in t.text() and len(separators(t)) == 1, separators(t))
t.keys("/"); t.keys("First\r", 0.3)
check("search shows a result", "Search: First" in t.text() and "1 results" in t.text(), t.text())
t.keys("\r", 0.3)
check("reader shows the title", "First article" in t.text())
check("reader shows details", "Sam" in t.text() and "2026-11-06" in t.text(), t.text())
check("reader shows structure", "Section" in t.text() and "• first point" in t.text() and "│ wise words" in t.text() and "let x = 1;" in t.text(), t.text())
check("links are numbered", "link[1]" in t.text(), t.text())
word = next((x for x, ch in t.screen.buffer[next(y for y, l in enumerate(t.screen.display) if "Hello world" in l)].items() if ch.data == "w" and ch.bold), None)
check("bold text is bold", word is not None)
check("opening marks as read", json.loads(rss("query", "SELECT count(*) FROM entry_state WHERE read_at IS NOT NULL").stdout)["rows"] == [[1]])

before = t.text()
t.keys(" ")
check("space scrolls", t.text() != before and "Section" not in t.text())
t.keys("G", 0.2)
check("the end of the article is reachable", "THE-LAST-LINE" in t.text() or "https://example.com/link" in t.text(), t.text())
check("the link list is at the end", "[1] https://example.com/link" in t.text(), t.text())
check("position is shown", "100%" in t.screen.display[-1], t.screen.display[-1])

t.keys("1", 0.5)
print("     status:", t.screen.display[-1].strip())
check("a number opens that link", os.path.exists(opened) and open(opened).read().strip() == "1:https://example.com/link", t.screen.display[-1])
os.remove(opened)
t.keys("o", 0.3)
got = open(opened).read().strip()
check("a hostile URL reaches the browser as one inert argument", got == "1:https://example.com/one?a=1&b=$(touch /tmp/pwned)" and not os.path.exists("/tmp/pwned"), got)
t.keys("7", 0.1)
check("a missing link number is reported", "No link 7" in t.screen.display[-1], t.screen.display[-1])

# Marks
t.keys("q", 0.2)
t.keys("\x1b", 0.3)
check("Escape clears the search", "Search:" not in t.text(), t.text())
t.keys("g", 0.2)
rows_before = json.loads(rss("query", "SELECT count(*) FROM entry_state WHERE starred_at IS NOT NULL").stdout)["rows"]
t.keys("s", 0.2)
rows = json.loads(rss("query", "SELECT count(*) FROM entry_state WHERE starred_at IS NOT NULL").stdout)["rows"]
check("starring reaches the database", rows_before == [[0]] and rows == [[1]], rows)
check("the star is shown", "★" in t.text(), t.text())
t.keys("m", 0.2)
rows = json.loads(rss("query", "SELECT count(*) FROM entry_state WHERE read_at IS NOT NULL").stdout)["rows"]
check("m marks the selected entry", rows == [[2]], rows)
t.keys("m", 0.2)
rows = json.loads(rss("query", "SELECT count(*) FROM entry_state WHERE read_at IS NOT NULL").stdout)["rows"]
check("m again unmarks it", rows == [[1]], rows)
t.keys("u", 0.3)
check("unread filter is announced", "unread only" in t.screen.display[-1].lower(), t.screen.display[-1])
check("read entries are hidden", "First article" not in t.text(), t.text())
t.keys("u", 0.3)
check("and shown again", "First article" in t.text())

# Injection
check("escape sequences in feeds do nothing", t.screen.title in ("", None) and b"\x1b]0;" not in t.raw, t.screen.title)
check("and the text around them still shows", "Evil]0;HACKED title[2J" in t.text(), t.text())

# Efficiency
got = t.keys("j", 0.15)
check("moving the cursor sends little", 0 < len(got) < 1500, len(got))
print(f"     one key press: {len(got)} bytes")
got = t.keys("?", 0.1)
check("help appears", "open a numbered link" in t.text(), t.text())
t.keys("x", 0.1)
check("any key closes help", "open a numbered link" not in t.text())

# Paging
t.keys("\t"); t.keys("j", 0.3); t.keys("\t", 0.2)
check("selecting a feed lists it", "Big Feed" in t.screen.display[0], t.screen.display[0])
for _ in range(6):
    t.keys("G", 0.2)
check("paging reaches the last of 350 items", "Item 0000" in t.text(), t.text())
t.keys("g", 0.2)
check("and back to the first", "Item 0349" in t.text(), t.text())
t.keys("\t"); t.keys("k", 0.3); t.keys("\t", 0.2)

# Live updates
state["live"] = 2
out = rss("refresh", "1").stdout
check("a refresh elsewhere found new entries", "2 new" in out, out)
check("new entries appear with no key press", t.wait_for("Live story 1", 4), t.text())

t.keys("R", 0.2)
check("refresh all reports", "Refresh" in t.screen.display[-1] or "fetching" in t.screen.display[-1], t.screen.display[-1])
check("refresh all finishes", t.wait_for("Refresh finished", 6), t.screen.display[-1])

# Resizing
for columns, rows, needle in ((200, 50, "Main Feed"), (90, 30, "Feeds"), (60, 20, "Main Feed"), (30, 10, "Live story"), (15, 4, "window too"), (130, 40, "Feeds")):
    t.resize(columns, rows)
    t.pump(0.3)
    t.keys("\x0c", 0.2)  # Ctrl-L repaints, since pyte starts blank after a resize.
    check(f"resize to {columns}x{rows}", needle.lower() in t.text().lower(), t.text())
    check(f"borders stay straight at {columns}x{rows}", len(separators(t)) <= 2, separators(t))

# Daemon loss
pid = int(subprocess.run(["lsof", "-t", home + "/rssd.lock"], capture_output=True, text=True).stdout.split()[0])
os.kill(pid, signal.SIGKILL)
time.sleep(0.2)
t.keys("j", 0.5); t.keys("k", 0.5)
check("survives the daemon dying", t.p.poll() is None)
check("and the daemon came back", "Main Feed" in rss("feeds").stdout)

# Exit
t.keys("\x03", 0.1)
code, after = t.finish()
check("Ctrl-C exits cleanly", code == 0, code)
check("the alternate screen is left", t.raw.rstrip().endswith(b"\x1b[?1049l"), t.raw[-120:])
check("terminal settings are restored", after == t.saved)

t = Term(); t.wait_for("Feeds"); t.p.send_signal(signal.SIGTERM)
code, after = t.finish()
check("SIGTERM restores the terminal", after == t.saved and code != 0, code)

p = subprocess.run([RSS, "tui"], env=env, input="", capture_output=True, text=True, timeout=10)
check("no terminal is a clear error", p.returncode == 1 and "NotATerminal" in p.stderr and "\x1b" not in p.stdout, p.stderr)

# Random keys
rng = random.Random(1)
t = Term(100, 30); t.wait_for("Feeds")
pieces = [b"j", b"k", b"g", b"G", b"\t", b"\r", b"\x1b", b"q", b"h", b"l", b"m", b"s", b"n", b"u", b"/", b"?", b" ", b"b", b"1",
          b"\x1b[A", b"\x1b[B", b"\x1b[5~", b"\x1b[6~", b"\x04", b"\x15", b"\x7f", "中".encode(), b"\xff", b"\x1b[", b"\x1b[999999999~", b"x"]
sent = 0
while sent < MONKEY:
    data = b"".join(rng.choice(pieces) for _ in range(rng.randint(1, 30)))
    data = data.replace(b"r", b"").replace(b"R", b"").replace(b"o", b"").replace(b"\x03", b"")
    # Quitting would end the test, so quit keys are replaced outside of prompts.
    data = data.replace(b"q", b"h")
    # "a" would start a real network fetch of random text.
    t.drain_write(data); sent += 1
    if sent % 200 == 0:
        columns, rows = rng.choice([(100, 30), (130, 40), (75, 24), (40, 12), (12, 3), (200, 60)])
        t.resize(columns, rows)
    if t.p.poll() is not None: break
t.pump(0.5)
alive = t.p.poll()
if alive is not None:
    print(t.raw[-1500:].decode(errors="replace"))
check(f"{MONKEY} random key bursts at random sizes", alive is None, alive)

t.resize(100, 30)
t.keys("\x1b", 0.1); t.keys("\x1b", 0.1); t.keys("\x0c", 0.3)
t.screen.reset()
t.keys("\x0c", 0.5)
check("it still responds after all that", "? help" in t.text() or "unread" in t.text() or "%" in t.text(), t.text())
t.keys("\x03", 0.1)
code, after = t.finish()
check("and still exits cleanly", code == 0 and after == t.saved, code)

rss("daemon", "stop"); server.shutdown(); shutil.rmtree(home); shutil.rmtree(shim)
print(f"\n{passed} checks passed")

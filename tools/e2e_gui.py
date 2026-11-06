#!/usr/bin/env python3
"""Drives the macOS app with key presses, against a local feed and a throwaway home.

    python3 tools/bundle_app.py && python3 tools/e2e_gui.py

Each scenario opens the app, plays keys, and checks which entry the daemon marked
read, since opening an article is the one effect that outlives the window.
"""
import http.server, json, os, pathlib, shutil, socketserver, subprocess, sys, tempfile, threading

root = pathlib.Path(__file__).resolve().parent.parent
app = root / "zig-out/rss_.app/Contents/MacOS"
home = tempfile.mkdtemp(prefix="rss-g-", dir="/tmp")
env = dict(os.environ, RSS_HOME=home, RSS_BIN=str(app / "rss"))
passed = 0

ITEMS = "".join(f"<item><title>Needle {name}</title><guid>{name}</guid><pubDate>{day} Nov 2026 09:00:00 GMT</pubDate><description>needle text</description></item>"
                for name, day in (("one", "05"), ("two", "04"), ("three", "03")))
FEED = f'<rss version="2.0"><channel><title>Local</title>{ITEMS}</channel></rss>'.encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "application/rss+xml")
        self.send_header("Content-Length", str(len(FEED))); self.end_headers(); self.wfile.write(FEED)


server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()


def rss(*args):
    return subprocess.run([str(app / "rss"), *args], env=env, capture_output=True, text=True, timeout=60, check=True).stdout


def read_titles():
    rows = json.loads(rss("query", "SELECT e.title FROM entries e JOIN entry_state s ON s.entry_id = e.id WHERE s.read_at IS NOT NULL ORDER BY e.sort_at DESC"))["rows"]
    return [row[0] for row in rows]


def play(name, keys, expected):
    global passed
    for entry in json.loads(rss("list", "--json"))["items"]:
        rss("mark", str(entry["id"]), "--unread")
    subprocess.run([str(app / "Reader"), "-theme", "light", "-followSystem", "NO"], env=dict(env, RSS_KEYS=keys),
                   capture_output=True, timeout=60)
    got = read_titles()
    if got != expected:
        print(f"FAIL {name}: expected {expected}, got {got}")
        rss("daemon", "stop"); shutil.rmtree(home); sys.exit(1)
    print(f"ok   {name}")
    passed += 1


rss("add", f"http://127.0.0.1:{server.server_address[1]}/feed.xml", "--allow-private")
play("command-F, type and Return opens the first result", "cmd+f needle return", ["Needle one"])
play("/ opens search too", "/ needle return", ["Needle one"])
play("the down arrow moves the selection", "cmd+f needle down return", ["Needle two"])
play("the up arrow moves it back", "cmd+f needle down down up return", ["Needle two"])
play("selection stops at both ends", "cmd+f needle up up down down down down return", ["Needle three"])
play("Esc closes without opening", "cmd+f needle esc return", [])
play("keys reach the list again after Esc", "cmd+f needle esc down return", ["Needle one"])
play("nothing found opens nothing", "cmd+f qqzzxx return", [])

rss("daemon", "stop")
shutil.rmtree(home)
print(f"\n{passed} checks passed")

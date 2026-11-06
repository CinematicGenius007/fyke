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
play("? shows shortcuts and swallows keys until closed", "? j return ? cmd+f needle return", ["Needle one"])
play("Esc closes shortcuts", "? esc cmd+f needle return", ["Needle one"])

# Themes. Clicks use window coordinates, which hold at the default window size.
DUSK = {"id": "dusk", "name": "Dusk", "base": "dark", "tokens": {"ground": "#1C1B29"}, "fonts": {"reading": "Georgia"}}
BUILT_IN_SAVE, CUSTOM_SAVE, CUSTOM_BACK, LIGHT_TILE = "click:1206,196", "click:1188,248", "click:1290,248", "click:1170,80"


def themes(name, start, keys, check):
    global passed
    path = pathlib.Path(home) / "config.json"
    config = json.loads(path.read_text())
    config["ui"] = start
    path.write_text(json.dumps(config))
    subprocess.run([str(app / "Reader")], env=dict(env, RSS_KEYS="t wait " + keys + " wait", RSS_SCREEN="feed"), capture_output=True, timeout=60)
    ui = json.loads(path.read_text())["ui"]
    if not check(ui):
        print(f"FAIL {name}: {ui}")
        rss("daemon", "stop"); shutil.rmtree(home); sys.exit(1)
    print(f"ok   {name}")
    passed += 1


on_dusk = {"theme": "dusk", "follow_system": False, "fonts": {"reading": "Inter"}, "themes": [DUSK]}
themes("a temporary font saves to its theme", on_dusk, CUSTOM_SAVE,
       lambda ui: ui["fonts"] == {} and ui["themes"][0]["fonts"]["reading"] == "Inter")
themes("a temporary font can be dropped", on_dusk, CUSTOM_BACK,
       lambda ui: ui["fonts"] == {} and ui["themes"][0]["fonts"]["reading"] == "Georgia")
themes("switching theme clears a temporary font", on_dusk, LIGHT_TILE,
       lambda ui: ui["theme"] == "light" and ui["fonts"] == {} and ui["themes"][0]["fonts"]["reading"] == "Georgia")
themes("a built-in saves as a new theme instead", {"theme": "light", "follow_system": False, "fonts": {"reading": "Inter"}}, BUILT_IN_SAVE + " wait Mine return",
       lambda ui: ui["theme"] == "mine" and ui["fonts"] == {} and ui["themes"][0]["base"] == "light" and ui["themes"][0]["fonts"]["reading"] == "Inter")

# The divider between the article list and the reader drags, and keeps where it was left.
config_path = pathlib.Path(home) / "config.json"
before_width = json.loads(config_path.read_text()).get("ui", {}).get("list_width", 375)
subprocess.run([str(app / "Reader")], env=dict(env, RSS_SCREEN="feed", RSS_FEED="0", RSS_KEYS="wait drag:611,500,691,500 wait wait"), capture_output=True, timeout=60)
width = json.loads(config_path.read_text()).get("ui", {}).get("list_width")
if width is None or abs(width - (before_width + 80)) > 2:
    print(f"FAIL the divider drags: {before_width} to {width}")
    rss("daemon", "stop"); shutil.rmtree(home); sys.exit(1)
print("ok   dragging the divider widens the article list and saves it")
passed += 1

# The data folder move. RSS_HOME is set, so the command refuses, which is the failure
# path: it must hand control back, and leave the data and the daemon as they were.
before = rss("feeds", "--json")
moved = tempfile.mkdtemp(prefix="rss-mv-", dir="/tmp")
subprocess.run([str(app / "Reader")], env=dict(env, RSS_SCREEN="settings", RSS_TAB="General", RSS_MOVE=moved + "/data", RSS_MOVE_RUN="1", RSS_KEYS="wait wait wait wait"),
               capture_output=True, timeout=60)
if rss("feeds", "--json") != before or os.path.exists(moved + "/data"):
    print("FAIL a refused move changes nothing")
    rss("daemon", "stop"); shutil.rmtree(home); sys.exit(1)
print("ok   a refused move changes nothing, and the daemon answers afterwards")
passed += 1
shutil.rmtree(moved)

rss("daemon", "stop")
shutil.rmtree(home)
print(f"\n{passed} checks passed")

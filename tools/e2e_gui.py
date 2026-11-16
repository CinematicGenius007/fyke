#!/usr/bin/env python3
"""Drives the macOS app with key presses, against a local feed and a throwaway home.

    python3 tools/bundle_app.py && python3 tools/e2e_gui.py

Each scenario opens the app, plays keys, and checks what the daemon holds afterwards,
such as which entry it marked read, since that is the effect that outlives the window.
The reader features run against a stand-in writer, and each of their screens is saved
as a picture in zig-out/gui-snapshots for a person to look at.
"""
import http.server, json, os, pathlib, shutil, socket, socketserver, subprocess, sys, tempfile, threading, time

# Unix socket paths are short, so macOS and Linux use /tmp. Windows has no /tmp.
TMP = tempfile.gettempdir() if os.name == "nt" else "/tmp"

root = pathlib.Path(__file__).resolve().parent.parent
app = root / "zig-out/Fyke.app/Contents/MacOS"
home = tempfile.mkdtemp(prefix="fyke-g-", dir=TMP)
# Writes a brief or an answer that cites the first sources it is given, as the writer
# contract in docs/reader-features.md asks, without calling any model.
WRITER = pathlib.Path(home) / "writer.py"
WRITER.write_text("""import json, re, sys
text = sys.stdin.read()
found = re.search(r"UNTRUSTED SOURCES JSON:\\n(.*)\\nEND SOURCES", text, re.S)
ids = [s["id"] for s in json.loads(found.group(1))] if found else []
print(json.dumps({"title": "Needles, briefly", "sections": [{"heading": "", "claims": [
    {"text": "Three needles arrived this week.", "sources": ids[:2] or ids},
    {"text": "The first one is the newest.", "sources": ids[:1]}]}]}))
""")
env = dict(os.environ, FYKE_HOME=home, FYKE_BIN=str(app / "fyke"), FYKE_WRITER_CMD=f"{sys.executable} {WRITER}")
snapshots = root / "zig-out/gui-snapshots"
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
    return subprocess.run([str(app / "fyke"), *args], env=env, capture_output=True, text=True, timeout=60, check=True).stdout


def read_titles():
    rows = json.loads(rss("query", "SELECT e.title FROM entries e JOIN entry_state s ON s.entry_id = e.id WHERE s.read_at IS NOT NULL ORDER BY e.sort_at DESC"))["rows"]
    return [row[0] for row in rows]


def play(name, keys, expected):
    global passed
    for entry in json.loads(rss("list", "--json"))["items"]:
        rss("mark", str(entry["id"]), "--unread")
    subprocess.run([str(app / "Reader"), "-theme", "light", "-followSystem", "NO"], env=dict(env, FYKE_KEYS=keys),
                   capture_output=True, timeout=60)
    got = read_titles()
    if got != expected:
        print(f"FAIL {name}: expected {expected}, got {got}")
        rss("daemon", "stop"); shutil.rmtree(home, ignore_errors=True); sys.exit(1)
    print(f"ok   {name}")
    passed += 1


rss("add", f"http://127.0.0.1:{server.server_address[1]}/feed.xml", "--allow-private")
# The daemon fetches a new feed in the background. The checks start once it holds all
# three articles, not after a fixed pause, because a cold start after a rebuild is slow.
deadline = time.monotonic() + 60
while len(json.loads(rss("list", "--json"))["items"]) < 3:
    if time.monotonic() > deadline:
        print("FAIL the feed was not fetched within 60 s"); rss("daemon", "stop"); shutil.rmtree(home, ignore_errors=True); sys.exit(1)
    time.sleep(0.1)
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
    subprocess.run([str(app / "Reader")], env=dict(env, FYKE_KEYS="t wait " + keys + " wait", FYKE_SCREEN="feed"), capture_output=True, timeout=60)
    ui = json.loads(path.read_text())["ui"]
    if not check(ui):
        print(f"FAIL {name}: {ui}")
        rss("daemon", "stop"); shutil.rmtree(home, ignore_errors=True); sys.exit(1)
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
subprocess.run([str(app / "Reader")], env=dict(env, FYKE_SCREEN="feed", FYKE_FEED="0", FYKE_KEYS="wait drag:611,500,691,500 wait wait"), capture_output=True, timeout=60)
width = json.loads(config_path.read_text()).get("ui", {}).get("list_width")
if width is None or abs(width - (before_width + 80)) > 2:
    print(f"FAIL the divider drags: {before_width} to {width}")
    rss("daemon", "stop"); shutil.rmtree(home, ignore_errors=True); sys.exit(1)
print("ok   dragging the divider widens the article list and saves it")
passed += 1

# The data folder move. FYKE_HOME is set, so the command refuses, which is the failure
# path: it must hand control back, and leave the data and the daemon as they were.
before = rss("feeds", "--json")
moved = tempfile.mkdtemp(prefix="fyke-mv-", dir=TMP)
subprocess.run([str(app / "Reader")], env=dict(env, FYKE_SCREEN="settings", FYKE_TAB="General", FYKE_MOVE=moved + "/data", FYKE_MOVE_RUN="1", FYKE_KEYS="wait wait wait wait"),
               capture_output=True, timeout=60)
if rss("feeds", "--json") != before or os.path.exists(moved + "/data"):
    print("FAIL a refused move changes nothing")
    rss("daemon", "stop"); shutil.rmtree(home, ignore_errors=True); sys.exit(1)
print("ok   a refused move changes nothing, and the daemon answers afterwards")
passed += 1
shutil.rmtree(moved, ignore_errors=True)

# Reader features: views, undo, catch up, briefs, answers, routines and the palette.

def call(method, params=None):
    """One request on the daemon's socket, for setup and checks the CLI has no command for."""
    with socket.socket(socket.AF_UNIX) as sock:
        sock.connect(str(pathlib.Path(home) / "fyked.sock"))
        sock.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            data += sock.recv(1 << 20)
    reply = json.loads(data)
    if "error" in reply:
        raise RuntimeError(f"{method}: {reply['error']}")
    return reply["result"]


def column(sql):
    return [row[0] for row in json.loads(rss("query", sql))["rows"]]


def fail(name, detail):
    print(f"FAIL {name}: {detail}")
    rss("daemon", "stop"); shutil.rmtree(home, ignore_errors=True); sys.exit(1)


def scenario(name, keys, check, screen=None, query=None, settle=0):
    """Resets reading state, plays keys on a screen, then asks `check` for a problem."""
    global passed
    for entry in json.loads(rss("list", "--json"))["items"]:
        rss("mark", str(entry["id"]), "--unread")
    later = column("SELECT entry_id FROM entry_state WHERE later_at IS NOT NULL")
    if later:
        call("entries.mark_many", {"ids": later, "later": False})
    extra = {"FYKE_KEYS": keys + " wait" * settle}
    if screen: extra["FYKE_SCREEN"] = screen
    if query: extra["FYKE_QUERY"] = query
    subprocess.run([str(app / "Reader"), "-theme", "light", "-followSystem", "NO"], env=dict(env, **extra), capture_output=True, timeout=90)
    problem = check()
    if problem:
        fail(name, problem)
    print(f"ok   {name}")
    passed += 1


def views():
    return column("SELECT name FROM views ORDER BY position, id")


scenario("command-S keeps a search as a view, named for its words", "cmd+f needle cmd+s wait wait return",
         lambda: None if views() == ["Needle"] else f"views {views()}")
scenario("command-Z takes the new view back", "cmd+f text cmd+s wait wait return wait cmd+z wait",
         lambda: None if views() == ["Needle"] else f"views {views()}")
scenario("catch up: left skips, down saves for later", "cmd+j wait left down wait",
         lambda: None if read_titles() == ["Needle one"] and column("SELECT e.title FROM entries e JOIN entry_state s ON s.entry_id = e.id WHERE s.later_at IS NOT NULL") == ["Needle two"]
         else f"read {read_titles()}")
scenario("catch up: command-Z puts the last one back", "cmd+j wait left left cmd+z wait",
         lambda: None if read_titles() == ["Needle one"] else f"read {read_titles()}")
scenario("the palette finds a command by its letters", "cmd+k markallread return wait",
         lambda: None if len(read_titles()) == 3 else f"read {read_titles()}")
scenario("command-Z takes back mark all read", "cmd+k markallread return wait wait cmd+z wait",
         lambda: None if read_titles() == [] else f"read {read_titles()}")

before = len(column("SELECT id FROM artifacts WHERE kind = 'digest'"))
scenario("command-R writes a brief, cited from the articles", "wait cmd+r", screen="today", settle=6,
         check=lambda: None if len(column("SELECT id FROM artifacts WHERE kind = 'digest'")) == before + 1 else "no brief")
scenario("a question becomes a cited answer", "wait", screen="ask", query="Which needle is newest?", settle=6,
         check=lambda: None if column("SELECT question FROM artifacts WHERE kind = 'answer'") == ["Which needle is newest?"] else "no answer")
scenario("a routine starts from a view and saves with command-S", "wait cmd+s wait", screen="routines",
         check=lambda: None if column("SELECT view_id FROM routines") == [call("views.list")["items"][0]["id"]] else "no routine")

# Pictures of every feature screen, in both themes, for a person to look at.
shutil.rmtree(snapshots, ignore_errors=True)
snapshots.mkdir(parents=True)
# The delay counts from the moment the app has loaded, so it covers animation only.
# `citation` is Today with source 1 pinned open, as a click on its number leaves it.
SHOTS = {screen: {"FYKE_SCREEN": screen} for screen in
         ["today", "view", "recipe", "routines", "catchup", "palette", "ask", "activity", "health", "toast", "search"]}
SHOTS["citation"] = {"FYKE_SCREEN": "today", "FYKE_PIN_CITATION": "1"}
for name, extra in SHOTS.items():
    for theme in ["light", "dark"]:
        target = snapshots / f"{name}-{theme}.png"
        subprocess.run([str(app / "Reader"), "-theme", theme, "-followSystem", "NO"], timeout=90, capture_output=True,
                       env=dict(env, FYKE_QUERY="needle", FYKE_SNAPSHOT=str(target), FYKE_SNAPSHOT_DELAY="2", **extra))
        if not target.exists() or target.stat().st_size < 10000:
            fail(f"snapshot {name} {theme}", "no picture")
for theme in ["light", "dark"]:
    target = snapshots / f"settings-agents-{theme}.png"
    subprocess.run([str(app / "Reader"), "-theme", theme, "-followSystem", "NO"], timeout=90, capture_output=True,
                   env=dict(env, FYKE_SCREEN="settings", FYKE_TAB="Agents", FYKE_SNAPSHOT=str(target), FYKE_SNAPSHOT_DELAY="2"))
    if not target.exists():
        fail(f"snapshot settings {theme}", "no picture")
print(f"ok   snapshots in {snapshots.relative_to(root)}")
passed += 1

rss("daemon", "stop")
shutil.rmtree(home, ignore_errors=True)
print(f"\n{passed} checks passed")

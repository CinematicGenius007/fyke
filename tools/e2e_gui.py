#!/usr/bin/env python3
"""Drives the macOS app with key presses, against a local feed and a throwaway home.

    python3 tools/bundle_app.py && python3 tools/e2e_gui.py
    python3 tools/e2e_gui.py --list                 names of the checks and screens
    python3 tools/e2e_gui.py --only today,settings  only those, and what they need first
    python3 tools/e2e_gui.py --visible              shows the windows and takes focus

Each scenario opens the app, plays keys, and checks what the daemon holds afterwards,
such as which entry it marked read, since that is the effect that outlives the window.
The reader features run against a stand-in writer, and each of their screens is saved
as a picture in zig-out/gui-snapshots for a person to look at.

Runs are headless unless --visible is given: the app never becomes active, has no Dock
icon, and its windows are transparent and let clicks through, so checks can run while
someone works at the Mac. gui/Sources/Reader/TestMode.swift explains how. The app exits
with status 3 if it ever becomes active anyway, and that fails the run.
"""
import argparse, http.server, json, os, pathlib, shutil, socket, socketserver, subprocess, sys, tempfile, threading, time

# Unix socket paths are short, so macOS and Linux use /tmp. Windows has no /tmp.
TMP = tempfile.gettempdir() if os.name == "nt" else "/tmp"

root = pathlib.Path(__file__).resolve().parent.parent
app = root / "zig-out/Fyke.app/Contents/MacOS"
snapshots = root / "zig-out/gui-snapshots"
SETTINGS_TABS = ["General", "Reading", "Tokens", "Agents", "Data"]
# Screens saved as pictures in both themes. `citation` is Today with source 1 pinned
# open, as a click on its number leaves it. `view` and `all` have their first article
# selected, which shows the list's top inset against the header.
SCREENS = ["today", "view", "all", "recipe", "routines", "catchup", "palette", "ask", "activity", "health", "toast", "search"]

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--only", help="comma-separated names from --list; what they depend on runs first")
parser.add_argument("--list", action="store_true", help="print the names of the checks and exit")
parser.add_argument("--visible", action="store_true", help="show windows and activate the app, as before headless mode")
args = parser.parse_args()

# Every check, in the order they run. `needs` names checks whose data this one reads:
# Today's picture needs a brief, a view's picture needs a view.
CHECKS = {}


def check(name, needs=(), tags=()):
    def register(run):
        CHECKS[name] = {"run": run, "needs": list(needs), "tags": set(tags) | {name}}
        return run
    return register


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
if not args.visible:
    env["FYKE_HEADLESS"] = "1"
passed = 0

ITEMS = "".join(f"<item><title>Needle {name}</title><guid>{name}</guid><pubDate>{day} Nov 2026 09:00:00 GMT</pubDate><description>needle text</description></item>"
                for name, day in (("one", "05"), ("two", "04"), ("three", "03")))
FEED = f'<rss version="2.0"><channel><title>Local</title>{ITEMS}</channel></rss>'.encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "application/rss+xml")
        self.send_header("Content-Length", str(len(FEED))); self.end_headers(); self.wfile.write(FEED)


def rss(*args):
    return subprocess.run([str(app / "fyke"), *args], env=env, capture_output=True, text=True, timeout=60, check=True).stdout


def fail(name, detail):
    print(f"FAIL {name}: {detail}")
    rss("daemon", "stop"); shutil.rmtree(home, ignore_errors=True); sys.exit(1)


def launch(extra, *flags, timeout=90):
    """Runs the app once. A headless app that became active exits with 3, which fails."""
    result = subprocess.run([str(app / "Reader"), *flags], env=dict(env, **extra), capture_output=True, timeout=timeout)
    if result.returncode == 3:
        fail("headless", result.stderr.decode().strip() or "the app became active")
    return result


def ok(name):
    global passed
    print(f"ok   {name}")
    passed += 1


def read_titles():
    rows = json.loads(rss("query", "SELECT e.title FROM entries e JOIN entry_state s ON s.entry_id = e.id WHERE s.read_at IS NOT NULL ORDER BY e.sort_at DESC"))["rows"]
    return [row[0] for row in rows]


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


def scenario(name, keys, check, screen=None, query=None, settle=0):
    """Resets reading state, plays keys on a screen, then asks `check` for a problem."""
    for entry in json.loads(rss("list", "--json"))["items"]:
        rss("mark", str(entry["id"]), "--unread")
    later = column("SELECT entry_id FROM entry_state WHERE later_at IS NOT NULL")
    if later:
        call("entries.mark_many", {"ids": later, "later": False})
    extra = {"FYKE_KEYS": keys + " wait" * settle}
    if screen: extra["FYKE_SCREEN"] = screen
    if query: extra["FYKE_QUERY"] = query
    launch(extra, "-theme", "light", "-followSystem", "NO")
    problem = check()
    if problem:
        fail(name, problem)
    ok(name)


def play(name, keys, expected):
    scenario(name, keys, lambda: None if read_titles() == expected else f"expected {expected}, got {read_titles()}")


def views():
    return column("SELECT name FROM views ORDER BY position, id")


@check("keys", tags=["search"])
def keys():
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


@check("themes")
def themes():
    path = pathlib.Path(home) / "config.json"

    def run(name, start, keys, test):
        config = json.loads(path.read_text()) if path.exists() else {}
        config["ui"] = start
        path.write_text(json.dumps(config))
        launch({"FYKE_KEYS": "t wait " + keys + " wait", "FYKE_SCREEN": "feed"}, timeout=60)
        ui = json.loads(path.read_text())["ui"]
        if not test(ui):
            fail(name, ui)
        ok(name)

    on_dusk = {"theme": "dusk", "follow_system": False, "fonts": {"reading": "Inter"}, "themes": [DUSK]}
    run("a temporary font saves to its theme", on_dusk, CUSTOM_SAVE,
        lambda ui: ui["fonts"] == {} and ui["themes"][0]["fonts"]["reading"] == "Inter")
    run("a temporary font can be dropped", on_dusk, CUSTOM_BACK,
        lambda ui: ui["fonts"] == {} and ui["themes"][0]["fonts"]["reading"] == "Georgia")
    run("switching theme clears a temporary font", on_dusk, LIGHT_TILE,
        lambda ui: ui["theme"] == "light" and ui["fonts"] == {} and ui["themes"][0]["fonts"]["reading"] == "Georgia")
    run("a built-in saves as a new theme instead", {"theme": "light", "follow_system": False, "fonts": {"reading": "Inter"}}, BUILT_IN_SAVE + " wait Mine return",
        lambda ui: ui["theme"] == "mine" and ui["fonts"] == {} and ui["themes"][0]["base"] == "light" and ui["themes"][0]["fonts"]["reading"] == "Inter")
    # Later checks take their theme from the command line, so a clean ui suits them.
    config = json.loads(path.read_text())
    config["ui"] = {}
    path.write_text(json.dumps(config))


@check("divider", tags=["list"])
def divider():
    """The divider between the article list and the reader drags, and keeps where it was left."""
    config_path = pathlib.Path(home) / "config.json"

    def config():
        return json.loads(config_path.read_text()) if config_path.exists() else {}

    before_width = config().get("ui", {}).get("list_width", 375)
    launch({"FYKE_SCREEN": "feed", "FYKE_FEED": "0", "FYKE_KEYS": "wait drag:611,500,691,500 wait wait"}, timeout=60)
    width = config().get("ui", {}).get("list_width")
    if width is None or abs(width - (before_width + 80)) > 2:
        fail("the divider drags", f"{before_width} to {width}")
    ok("dragging the divider widens the article list and saves it")
    # Later pictures use the standard width.
    saved = config()
    saved.get("ui", {}).pop("list_width", None)
    config_path.write_text(json.dumps(saved))


@check("move", tags=["settings"])
def move():
    """FYKE_HOME is set, so the data folder move refuses, which is the failure path: it
    must hand control back, and leave the data and the daemon as they were."""
    before = rss("feeds", "--json")
    moved = tempfile.mkdtemp(prefix="fyke-mv-", dir=TMP)
    launch({"FYKE_SCREEN": "settings", "FYKE_TAB": "General", "FYKE_MOVE": moved + "/data", "FYKE_MOVE_RUN": "1", "FYKE_KEYS": "wait wait wait wait"}, timeout=60)
    if rss("feeds", "--json") != before or os.path.exists(moved + "/data"):
        fail("a refused move changes nothing", "data changed")
    ok("a refused move changes nothing, and the daemon answers afterwards")
    shutil.rmtree(moved, ignore_errors=True)


@check("view-save", tags=["view", "undo"])
def view_save():
    scenario("command-S keeps a search as a view, named for its words", "cmd+f needle cmd+s wait wait return",
             lambda: None if views() == ["Needle"] else f"views {views()}")
    scenario("command-Z takes the new view back", "cmd+f text cmd+s wait wait return wait cmd+z wait",
             lambda: None if views() == ["Needle"] else f"views {views()}")


@check("catchup-keys", tags=["catchup", "undo"])
def catchup_keys():
    later = "SELECT e.title FROM entries e JOIN entry_state s ON s.entry_id = e.id WHERE s.later_at IS NOT NULL"
    scenario("catch up: left skips, down saves for later", "cmd+j wait left down wait",
             lambda: None if read_titles() == ["Needle one"] and column(later) == ["Needle two"] else f"read {read_titles()}")
    scenario("catch up: command-Z puts the last one back", "cmd+j wait left left cmd+z wait",
             lambda: None if read_titles() == ["Needle one"] else f"read {read_titles()}")


@check("palette-keys", tags=["palette", "undo"])
def palette_keys():
    scenario("the palette finds a command by its letters", "cmd+k markallread return wait",
             lambda: None if len(read_titles()) == 3 else f"read {read_titles()}")
    scenario("command-Z takes back mark all read", "cmd+k markallread return wait wait cmd+z wait",
             lambda: None if read_titles() == [] else f"read {read_titles()}")


@check("brief", tags=["today"])
def brief():
    before = len(column("SELECT id FROM artifacts WHERE kind = 'digest'"))
    scenario("command-R writes a brief, cited from the articles", "wait cmd+r", screen="today", settle=6,
             check=lambda: None if len(column("SELECT id FROM artifacts WHERE kind = 'digest'")) == before + 1 else "no brief")


@check("answer", needs=["view-save"], tags=["ask"])
def answer():
    scenario("a question becomes a cited answer", "wait", screen="ask", query="Which needle is newest?", settle=6,
             check=lambda: None if "Which needle is newest?" in column("SELECT question FROM artifacts WHERE kind = 'answer'") else "no answer")


@check("routine-save", needs=["view-save"], tags=["routines"])
def routine_save():
    def test():
        routines = column("SELECT view_id FROM routines")
        return None if call("views.list")["items"][0]["id"] in routines else "no routine"
    scenario("a routine starts from a view and saves with command-S", "wait cmd+s wait", screen="routines", check=test)


def snapshot(name, extra):
    for theme in ["light", "dark"]:
        target = snapshots / f"{name}-{theme}.png"
        target.unlink(missing_ok=True)
        # The delay counts from the moment the app has loaded, so it covers animation only.
        launch(dict(FYKE_QUERY="needle", FYKE_SNAPSHOT=str(target), FYKE_SNAPSHOT_DELAY="2", **extra), "-theme", theme, "-followSystem", "NO")
        if not target.exists() or target.stat().st_size < 10000:
            fail(f"snapshot {name} {theme}", "no picture")
    ok(f"snapshot {name} in {snapshots.relative_to(root)}")


# What each picture needs in the database before it means anything.
SCREEN_NEEDS = {"today": ["brief"], "citation": ["brief"], "recipe": ["brief"], "view": ["view-save"],
                "routines": ["routine-save"], "ask": ["answer"]}
for screen in SCREENS + ["citation"]:
    extra = {"FYKE_SCREEN": "today", "FYKE_PIN_CITATION": "1"} if screen == "citation" else {"FYKE_SCREEN": screen}
    check(f"shot:{screen}", needs=SCREEN_NEEDS.get(screen, []), tags=[screen, "snapshots"])(
        lambda screen=screen, extra=extra: snapshot(screen, extra))
for tab in SETTINGS_TABS:
    name = f"settings-{tab.lower()}"
    check(f"shot:{name}", tags=[name, "settings", "snapshots"])(
        # With the title bar, which holds the window buttons, so their placement shows.
        lambda name=name, tab=tab: snapshot(name, {"FYKE_SCREEN": "settings", "FYKE_TAB": tab, "FYKE_SNAPSHOT_CHROME": "1"}))


def select(names):
    """The checks named, by name or tag, with what they need, in registration order."""
    wanted = {key for key, check in CHECKS.items() if check["tags"] & names}
    unknown = names - {tag for check in CHECKS.values() for tag in check["tags"]}
    if unknown:
        sys.exit(f"unknown names: {', '.join(sorted(unknown))}. See --list.")
    pending = list(wanted)
    while pending:
        for need in CHECKS[pending.pop()]["needs"]:
            if need not in wanted:
                wanted.add(need); pending.append(need)
    return [key for key in CHECKS if key in wanted]


if args.list:
    shutil.rmtree(home, ignore_errors=True)
    for key, value in CHECKS.items():
        tags = sorted(value["tags"] - {key})
        print(f"{key:24} {' '.join(tags)}" + (f"   needs {', '.join(value['needs'])}" if value["needs"] else ""))
    sys.exit(0)

chosen = select({name.strip() for name in args.only.split(",") if name.strip()}) if args.only else list(CHECKS)

server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
rss("add", f"http://127.0.0.1:{server.server_address[1]}/feed.xml", "--allow-private")
# The daemon fetches a new feed in the background. The checks start once it holds all
# three articles, not after a fixed pause, because a cold start after a rebuild is slow.
deadline = time.monotonic() + 60
while len(json.loads(rss("list", "--json"))["items"]) < 3:
    if time.monotonic() > deadline:
        fail("setup", "the feed was not fetched within 60 s")
    time.sleep(0.1)

snapshots.mkdir(parents=True, exist_ok=True)
print(f"{'visible' if args.visible else 'headless'}: {', '.join(chosen)}")
for key in chosen:
    CHECKS[key]["run"]()

rss("daemon", "stop")
shutil.rmtree(home, ignore_errors=True)
print(f"\n{passed} checks passed")

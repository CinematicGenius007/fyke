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
import argparse, json, os, pathlib, shutil, socket, subprocess, sys, tempfile, time

import gui_fixtures as fixtures

# Unix socket paths are short, so macOS and Linux use /tmp. Windows has no /tmp.
TMP = tempfile.gettempdir() if os.name == "nt" else "/tmp"

root = pathlib.Path(__file__).resolve().parent.parent
app = root / "zig-out/Fyke.app/Contents/MacOS"
snapshots = root / "zig-out/gui-snapshots"
SETTINGS_TABS = ["General", "Reading", "Tokens", "Agents", "Data"]
# Screens saved as pictures in both themes. `citation` is Today with source 1 pinned
# open, as a click on its number leaves it. `view` and `all` have their first article
# selected, which shows the list's top inset against the header.
SCREENS = ["today", "view", "all", "recipe", "routines", "catchup", "palette", "ask", "activity", "health", "toast", "search", "shortcuts"]
# Pictures of the feed tree with a folder in it.
TREE_SCREENS = ["rename-folder", "rename-feed", "delete-folder"]
# Headless runs never attach a sheet, so these pictures hold the sheet alone.
ADD_SCREENS = {"add": "news", "add-found": "/thread.xml", "add-none": "/missing", "add-multiple": "/feed-list"}

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--only", help="comma-separated names from --list; what they depend on runs first")
parser.add_argument("--list", action="store_true", help="print the names of the checks and exit")
parser.add_argument("--visible", action="store_true", help="show windows and activate the app, as before headless mode")
args = parser.parse_args()

# Every check, in the order they run. `needs` names checks whose data this one reads:
# Today's picture needs a brief, a view's picture needs a view.
CHECKS = {}


def check(name, needs=(), tags=()):
    # Every picture has the Needle view and its routine in the sidebar, as a full run leaves
    # them, so a picture looks the same however few checks run before it. The desktop's
    # pictures start from the same (desktop/tests/e2e/fixtures.ts `afterRoutineSave`).
    if name.startswith("shot:") and "routine-save" not in needs:
        needs = [*needs, "routine-save"]
    def register(run):
        CHECKS[name] = {"run": run, "needs": list(needs), "tags": set(tags) | {name}}
        return run
    return register


home = tempfile.mkdtemp(prefix="fyke-g-", dir=TMP)
# The feed server starts now, because the daemon reads its address when it starts.
base = fixtures.serve()
env = dict(os.environ, **fixtures.environment(home, app / "fyke", base))
if not args.visible:
    env["FYKE_HEADLESS"] = "1"
passed = 0


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
DUSK = fixtures.DUSK
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

    before_width = config().get("ui", {}).get("list_width", 368)
    launch({"FYKE_SCREEN": "feed", "FYKE_FEED": "0", "FYKE_KEYS": "wait drag:604,500,684,500 wait wait"}, timeout=60)
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


@check("settings-route", tags=["settings"])
def settings_route():
    """Settings opens in the main window. While it shows, reader keys such as n do
    nothing; Esc, or any other destination, returns to the reader."""
    play("command-comma opens Settings, which keeps reader keys from the list", "cmd+, wait n wait", [])
    play("Esc closes Settings and keys reach the reader again", "cmd+, wait esc n wait", ["Needle one"])
    play("the palette opens Settings too", "cmd+k settings return wait n wait", [])
    play("another destination closes Settings", "cmd+, wait cmd+2 wait n wait", ["Needle one"])


@check("mark-all")
def mark_all():
    """Mark all read covers the place showing. Starred is not a set of feeds, so the palette
    does not offer it there (and the menu item is disabled); it used to mark every feed."""
    play("Mark all read is not offered in Starred", "cmd+3 wait cmd+k markallread return wait wait", [])
    play("Mark all read in All marks every article", "cmd+2 wait cmd+k markallread return wait wait",
         ["Needle one", "Needle two", "Needle three"])


@check("rename", tags=["sidebar"])
def rename():
    """Renaming in the sidebar takes every key. The text holds letters that are reader
    shortcuts (j, n, s, m, r, o, u, t), Return saves it, and Esc leaves the name as it was."""
    typed = "jumpsnorth"

    def renamed(screen, sql, original):
        launch({"FYKE_SCREEN": screen, "FYKE_KEYS": f"wait {typed} return wait"}, timeout=60)
        name = column(sql)[0]
        # Focus may select the old name, so the typing replaces it, or leave the caret after it.
        return None if name in (typed, original + typed) else f"expected {typed!r}, got {name!r}"

    folder = call("folders.add", {"name": "Reading"})["id"]
    sql = f"SELECT name FROM folders WHERE id = {folder}"
    problem = renamed("rename-folder", sql, "Reading")
    if problem:
        fail("Return saves a folder's new name", problem)
    ok("Return saves a folder's new name, with shortcut letters in it")
    before = column(sql)[0]
    launch({"FYKE_SCREEN": "rename-folder", "FYKE_KEYS": "wait xyz esc wait"}, timeout=60)
    if column(sql)[0] != before:
        fail("Esc cancels a rename", column(sql)[0])
    ok("Esc cancels a rename")
    call("folders.remove", {"id": folder, "delete_contents": False})

    feed = column("SELECT id FROM feeds ORDER BY id")[0]
    problem = renamed("rename-feed", f"SELECT coalesce(title_override, title) FROM feeds WHERE id = {feed}", "Local")
    if problem:
        fail("Return saves a feed's new name", problem)
    ok("Return saves a feed's new name")
    call("feeds.update", {"id": feed, "title": "Local"})


@check("font-weight",tags=["settings", "fonts"])
def font_weight():
    """Weights saved in the config are read at launch and kept, and the Reading tab with
    its weight menus draws."""
    config_path = pathlib.Path(home) / "config.json"
    saved = json.loads(config_path.read_text()) if config_path.exists() else {}
    ui = saved.setdefault("ui", {})
    ui["weights"] = {"reading": -1, "title": 1, "ui": 0, "code": 0}
    config_path.write_text(json.dumps(saved))
    target = snapshots / "settings-reading-weights.png"
    target.unlink(missing_ok=True)
    launch({"FYKE_SCREEN": "settings", "FYKE_TAB": "Reading", "FYKE_KEYS": "wait wait", "FYKE_SNAPSHOT": str(target), "FYKE_SNAPSHOT_DELAY": "1"},
           "-theme", "light", "-followSystem", "NO")
    kept = json.loads(config_path.read_text()).get("ui", {}).get("weights")
    if kept != {"reading": -1, "title": 1, "ui": 0, "code": 0}:
        fail("font weights", f"weights after launch: {kept}")
    ok("saved font weights survive a launch")
    if not target.exists() or target.stat().st_size < 10000:
        fail("snapshot settings reading", "no picture")
    ok("the Reading tab draws with the weight menus")
    saved["ui"].pop("weights", None)
    config_path.write_text(json.dumps(saved))


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


@check("discussion", tags=["comments", "reader"])
def discussion():
    """The Comments link in a Hacker News story, and the c key, load its thread under
    the article. Opening the story alone does not ask for the thread."""
    feed = call("feeds.add", {"url": f"{base}/thread.xml", "allow_private_network": True})["id"]
    try:
        fixtures.thread_requests.clear()
        launch({"FYKE_KEYS": "cmd+f unkernel return wait wait"}, "-theme", "light", "-followSystem", "NO")
        if fixtures.thread_requests:
            fail("discussion", f"opening the story asked for its thread: {fixtures.thread_requests}")
        ok("opening a story leaves its comments unasked")
        for theme in ["light", "dark"]:
            target = snapshots / f"comments-{theme}.png"
            target.unlink(missing_ok=True)
            fixtures.thread_requests.clear()
            launch({"FYKE_KEYS": "cmd+f unkernel return wait c wait wait", "FYKE_SNAPSHOT": str(target), "FYKE_SNAPSHOT_DELAY": "1"},
                   "-theme", theme, "-followSystem", "NO")
            if fixtures.thread_requests != ["/items/41"]:
                fail("discussion", f"c should load the thread once, asked {fixtures.thread_requests}")
            if not target.exists() or target.stat().st_size < 10000:
                fail(f"snapshot comments {theme}", "no picture")
        ok(f"c loads the thread under the article, in {snapshots.relative_to(root)}")
    finally:
        call("feeds.remove", {"id": feed})


def snapshot(name, extra):
    for theme in ["light", "dark"]:
        target = snapshots / f"{name}-{theme}.png"
        target.unlink(missing_ok=True)
        # The delay counts from the moment the app has loaded, so it covers animation only.
        launch({"FYKE_QUERY": "needle", "FYKE_SNAPSHOT": str(target), "FYKE_SNAPSHOT_DELAY": "2", **extra}, "-theme", theme, "-followSystem", "NO")
        if not target.exists() or target.stat().st_size < 10000:
            fail(f"snapshot {name} {theme}", "no picture")
    ok(f"snapshot {name} in {snapshots.relative_to(root)}")


# What each picture needs in the database before it means anything.
SCREEN_NEEDS = {"today": ["brief"], "citation": ["brief"], "recipe": ["brief"], "view": ["view-save"],
                "routines": ["routine-save"], "ask": ["answer"]}
def screen_snapshot(screen):
    extra = {"FYKE_SCREEN": screen}
    if screen == "citation":
        extra = {"FYKE_SCREEN": "today", "FYKE_PIN_CITATION": "1"}
    elif screen == "catchup":
        entries = call("entries.list", {"limit": 500})["items"]
        call("entries.mark_many", {"ids": [entry["id"] for entry in entries], "read": False, "later": False})
    snapshot(screen, extra)


for screen in SCREENS + ["citation"]:
    check(f"shot:{screen}", needs=SCREEN_NEEDS.get(screen, []), tags=[screen, "snapshots"])(
        lambda screen=screen: screen_snapshot(screen))


def tree_snapshot(name):
    """A picture with Local inside a folder named Reading. The folder goes again after,
    with Local back at the top level, so later pictures see the usual tree."""
    folder = call("folders.add", {"name": "Reading"})["id"]
    local = call("feeds.list")["items"][0]["id"]
    call("feeds.update", {"id": local, "folder_id": folder})
    entries = call("entries.list", {"limit": 500})["items"]
    call("entries.mark_many", {"ids": [entry["id"] for entry in entries], "read": False})
    try:
        snapshot(name, {"FYKE_SCREEN": name})
    finally:
        call("folders.remove", {"id": folder})


for screen in TREE_SCREENS:
    check(f"shot:{screen}", tags=[screen, "snapshots"])(lambda screen=screen: tree_snapshot(screen))
for name, address in ADD_SCREENS.items():
    check(f"shot:{name}", tags=[name, "snapshots"])(lambda name=name, address=address: snapshot(
        name, {"FYKE_SCREEN": "add", "FYKE_SNAPSHOT_SHEET": "1", "FYKE_ADDRESS": base + address if address.startswith("/") else address}))
for tab in SETTINGS_TABS:
    name = f"settings-{tab.lower()}"
    check(f"shot:{name}", tags=[name, "settings", "snapshots"])(
        # Settings is in the main window, beside the sidebar.
        lambda name=name, tab=tab: snapshot(name, {"FYKE_SCREEN": "settings", "FYKE_TAB": tab}))


def starred_snapshot(name):
    """Starred with the newest article starred, or with none."""
    entries = call("entries.list", {"limit": 500})["items"]
    ids = [entry["id"] for entry in entries]
    call("entries.mark_many", {"ids": ids, "starred": False, "read": False})
    if name == "starred":
        call("entries.mark_many", {"ids": ids[:1], "starred": True})
    try:
        snapshot(name, {"FYKE_SCREEN": "starred"})
    finally:
        call("entries.mark_many", {"ids": ids, "starred": False})


def empty_view_snapshot():
    """A view that matches nothing, with its "Include read articles" way out."""
    view = call("views.put", {"name": "Nothing yet", "rule": {"words": "zzqxv"}})["id"]
    try:
        unread_snapshot("view-empty", "view-empty")
    finally:
        call("views.remove", {"id": view, "detach": True})


def theme_snapshot(theme, screen="all"):
    """All or a feed, in one of the built-in themes that are neither light nor dark."""
    name = f"{screen}-{theme}"
    target = snapshots / f"{name}.png"
    target.unlink(missing_ok=True)
    entries = call("entries.list", {"limit": 500})["items"]
    call("entries.mark_many", {"ids": [entry["id"] for entry in entries], "read": False})
    launch(dict(FYKE_SCREEN=screen, FYKE_SNAPSHOT=str(target), FYKE_SNAPSHOT_DELAY="2"), "-theme", theme, "-followSystem", "NO")
    if not target.exists() or target.stat().st_size < 10000:
        fail(f"snapshot {name}", "no picture")
    ok(f"snapshot {name} in {snapshots.relative_to(root)}")


for name in ["starred", "starred-empty"]:
    check(f"shot:{name}", tags=[name, "snapshots"])(lambda name=name: starred_snapshot(name))
check("shot:folder", tags=["folder", "snapshots"])(lambda: tree_snapshot("folder"))
def unread_snapshot(name, screen):
    """A picture with every article unread, whatever earlier checks opened."""
    entries = call("entries.list", {"limit": 500})["items"]
    call("entries.mark_many", {"ids": [entry["id"] for entry in entries], "read": False})
    snapshot(name, {"FYKE_SCREEN": screen})


check("shot:feed", tags=["feed", "snapshots"])(lambda: unread_snapshot("feed", "feed"))
check("shot:view-empty", tags=["view-empty", "snapshots"])(empty_view_snapshot)


def caught_up_snapshot():
    """S13: catch-up with nothing unread, finished before it starts."""
    entries = call("entries.list", {"limit": 500})["items"]
    ids = [entry["id"] for entry in entries]
    call("entries.mark_many", {"ids": ids, "read": True})
    try:
        snapshot("catchup-done", {"FYKE_SCREEN": "catchup"})
    finally:
        call("entries.mark_many", {"ids": ids, "read": False})


check("shot:catchup-done", tags=["catchup-done", "snapshots"])(caught_up_snapshot)
check("shot:search-none", tags=["search-none", "snapshots"])(
    lambda: snapshot("search-none", {"FYKE_SCREEN": "search", "FYKE_QUERY": "qqzzxx"}))
def own_home_snapshot(name, prepare=lambda home: {}):
    """A picture with a data folder of its own, which `prepare` may change and whose
    daemon stops again after. With nothing prepared it is the first run: no feeds."""
    own = tempfile.mkdtemp(prefix="fyke-f-", dir=TMP)
    try:
        snapshot(name, {"FYKE_HOME": own, **prepare(pathlib.Path(own))})
    finally:
        subprocess.run([str(app / "fyke"), "daemon", "stop"], env=dict(env, FYKE_HOME=own), capture_output=True, timeout=60)
        shutil.rmtree(own, ignore_errors=True)


def silent_service(home):
    """S30: a stand-in for fyke that exits at once, so the service never answers."""
    program = home / "fyke-silent"
    program.write_text("#!/bin/sh\nexit 0\n")
    program.chmod(0o755)
    return {"FYKE_BIN": str(program)}


def config_mistake(home):
    """S30: config.json that cannot be parsed."""
    (home / "config.json").write_text('{"ui": {"theme": "light",, }')
    return {}


def write_brief(fails):
    """Runs a brief to its end with the stand-in writer, told to fail or not."""
    flag = pathlib.Path(home) / "writer-fails"
    if fails:
        flag.write_text("")
    try:
        last = max((job["id"] for job in call("jobs.list", {"limit": 50})["items"]), default=0)
        call("briefs.run", {"rule": {"state": "unread"}})
        deadline = time.monotonic() + 60
        while True:
            jobs = [job for job in call("jobs.list", {"limit": 50})["items"] if job["id"] > last]
            if jobs and all(job.get("status", job.get("state")) in ("done", "failed", "cancelled") for job in jobs):
                return jobs
            if time.monotonic() > deadline:
                fail("write a brief", f"jobs did not finish: {jobs}")
            time.sleep(0.2)
    finally:
        flag.unlink(missing_ok=True)


def brief_failed_snapshot():
    """S3: Today after the writer failed, then a brief that succeeds so the failure no
    longer needs anyone."""
    jobs = write_brief(fails=True)
    if not any(job.get("status", job.get("state")) == "failed" for job in jobs):
        fail("the stand-in writer fails", f"jobs: {jobs}")
    try:
        snapshot("today-failed", {"FYKE_SCREEN": "today"})
    finally:
        write_brief(fails=False)


check("shot:today-failed", tags=["today-failed", "snapshots"], needs=["brief"])(brief_failed_snapshot)
check("shot:first-run", tags=["first-run", "snapshots"])(lambda: own_home_snapshot("first-run"))
check("shot:unavailable", tags=["unavailable", "snapshots"])(lambda: own_home_snapshot("unavailable", silent_service))
check("shot:config-mistake", tags=["config-mistake", "snapshots"])(lambda: own_home_snapshot("config-mistake", config_mistake))
for theme in ["newsprint", "terminal"]:
    for screen in ["all", "feed"]:
        check(f"shot:{screen}-{theme}", tags=[f"{screen}-{theme}", "themes", "snapshots"])(lambda theme=theme, screen=screen: theme_snapshot(theme, screen))


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

problem = fixtures.prepare(app / "fyke", env, base)
if problem:
    fail("setup", problem)

snapshots.mkdir(parents=True, exist_ok=True)
print(f"{'visible' if args.visible else 'headless'}: {', '.join(chosen)}")
for key in chosen:
    CHECKS[key]["run"]()

rss("daemon", "stop")
shutil.rmtree(home, ignore_errors=True)
print(f"\n{passed} checks passed")

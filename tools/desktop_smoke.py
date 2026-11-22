#!/usr/bin/env python3
"""X12: a smoke test of the built desktop app through tauri-driver, on Windows and Linux CI.

    python tools/desktop_smoke.py --app <path to the built app> [--driver tauri-driver]
        [--native-driver <msedgedriver or WebKitWebDriver>]

It starts tauri-driver, opens the real app in a data folder of its own (FYKE_HOME, empty,
removed after), and checks that the first run shows, that an address carries into Add a
feed, and that the window's title is Fyke. It speaks plain WebDriver over HTTP, so it needs
nothing beyond Python. Never run it on a Mac: tauri-driver has no macOS support, and the
checks must not open real windows there.
"""
import argparse, json, os, shutil, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--driver", default="tauri-driver")
parser.add_argument("--native-driver")
parser.add_argument("--fyke", help="the fyke program, to stop the daemon after")
args = parser.parse_args()

if sys.platform == "darwin":
    sys.exit("tauri-driver does not run on macOS; this check is for Windows and Linux CI.")

failures = []


def ok(name):
    print(f"ok   {name}")


def fail(name, why):
    failures.append(name)
    print(f"FAIL {name}: {why}")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


port = free_port()
base = f"http://127.0.0.1:{port}"


def request(method, path, body=None, timeout=60):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as reply:
            return json.load(reply)["value"]
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"{method} {path}: {error.code} {error.read().decode(errors='replace')[:400]}") from None
    except OSError as error:
        # tauri-driver listens before its native driver does, and drops requests until
        # then; a refused or dropped connection is worth another try.
        raise RuntimeError(f"{method} {path}: {error!r}") from None


def wait_for(probe, seconds=30):
    deadline = time.time() + seconds
    last = None
    while time.time() < deadline:
        try:
            value = probe()
            if value:
                return value
        except RuntimeError as error:
            last = error
        time.sleep(0.25)
    raise RuntimeError(f"timed out{f' ({last})' if last else ''}")


home = tempfile.mkdtemp(prefix="fyke-smoke-")
env = dict(os.environ, FYKE_HOME=home)
if sys.platform == "win32":
    # A profile of its own: WebView2 joins any browser process already using the app's
    # profile, and that process never opens the debugging port msedgedriver asks for.
    env["WEBVIEW2_USER_DATA_FOLDER"] = os.path.join(home, "webview2")
command = [args.driver, "--port", str(port)]
if args.native_driver:
    command += ["--native-driver", args.native_driver]
driver = subprocess.Popen(command, env=env)
session = None
try:
    wait_for(lambda: request("GET", "/status", timeout=2) is not None, 30)
    ok("tauri-driver is listening")

    capabilities = {"capabilities": {"alwaysMatch": {"browserName": "wry", "tauri:options": {"application": os.path.abspath(args.app)}}}}
    session = request("POST", "/session", capabilities, timeout=120)["sessionId"]
    ok("the app opens in a WebDriver session")

    def find(css):
        return request("POST", f"/session/{session}/element", {"using": "css selector", "value": css})

    def element_id(found):
        return next(iter(found.values()))

    def text(css):
        return request("GET", f"/session/{session}/element/{element_id(find(css))}/text")

    try:
        wait_for(lambda: find("html[data-ready]"), 60)
        ok("the page is ready")
    except RuntimeError as error:
        fail("the page is ready", error)

    try:
        heading = wait_for(lambda: text(".first-run h1"), 30)
        if heading == "Nothing to read yet.":
            ok("an empty data folder shows the first run")
        else:
            fail("an empty data folder shows the first run", f"heading was {heading!r}")
        words = text(".first-run p")
        if "this PC" in words or "this computer" in words:
            ok("the first run names this computer")
        else:
            fail("the first run names this computer", words)
    except RuntimeError as error:
        fail("an empty data folder shows the first run", error)

    try:
        field = element_id(find(".first-run input"))
        request("POST", f"/session/{session}/element/{field}/value", {"text": "example.org\n"})
        dialog = wait_for(lambda: find("dialog.add-feed[open] input"), 15)
        value = request("GET", f"/session/{session}/element/{element_id(dialog)}/property/value")
        if value == "example.org":
            ok("an address carries into Add a feed")
        else:
            fail("an address carries into Add a feed", f"field held {value!r}")
    except RuntimeError as error:
        fail("an address carries into Add a feed", error)

    title = request("GET", f"/session/{session}/title")
    if title == "Fyke":
        ok("the window is titled Fyke")
    else:
        fail("the window is titled Fyke", f"title was {title!r}")
except RuntimeError as error:
    fail("smoke test", error)
finally:
    if session:
        try:
            request("DELETE", f"/session/{session}", timeout=30)
        except (RuntimeError, OSError):
            pass
    driver.terminate()
    try:
        driver.wait(timeout=15)
    except subprocess.TimeoutExpired:
        driver.kill()
    if args.fyke:
        subprocess.run([args.fyke, "daemon", "stop"], env=env, capture_output=True, timeout=60)
    shutil.rmtree(home, ignore_errors=True)

print(f"\n{'all checks passed' if not failures else f'{len(failures)} failed: ' + ', '.join(failures)}")
sys.exit(1 if failures else 0)

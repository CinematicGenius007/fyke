#!/usr/bin/env python3
"""The data every GUI check runs against, shared by the Mac app's tools/e2e_gui.py and
the desktop app's Playwright suite (desktop/tests/e2e), so both draw the same screens.

    python3 tools/gui_fixtures.py --home DIR --fyke PATH

prepares DIR the way e2e_gui.py does (a local feed with three needles, fetched; a
stand-in writer; a Hacker News thread), prints one JSON line with the environment the
app needs, then serves the feed until stdin closes. The daemon is left running; stop it
with `fyke daemon stop`.
"""
import http.server, json, os, pathlib, socketserver, subprocess, sys, threading, time

# Writes a brief or an answer that cites the first sources it is given, as the writer
# contract in docs/reader-features.md asks, without calling any model.
WRITER_SOURCE = """import json, re, sys
text = sys.stdin.read()
found = re.search(r"UNTRUSTED SOURCES JSON:\\n(.*)\\nEND SOURCES", text, re.S)
ids = [s["id"] for s in json.loads(found.group(1))] if found else []
print(json.dumps({"title": "Needles, briefly", "sections": [{"heading": "", "claims": [
    {"text": "Three needles arrived this week.", "sources": ids[:2] or ids},
    {"text": "The first one is the newest.", "sources": ids[:1]}]}]}))
"""

ITEMS = "".join(f"<item><title>Needle {name}</title><guid>{name}</guid><pubDate>{day} Nov 2026 09:00:00 GMT</pubDate><description>needle text</description></item>"
                for name, day in (("one", "05"), ("two", "04"), ("three", "03")))
FEED = f'<rss version="2.0"><channel><title>Local</title>{ITEMS}</channel></rss>'.encode()

# A Hacker News story, and its thread as the Algolia items API returns it. The
# discussion check adds this feed, and removes it again so the others see three needles.
THREAD_FEED = (b'<rss version="2.0"><channel><title>Hacker News</title><item><title>Unkernel in WASM</title>'
               b'<link>https://example.org/unkernel</link><comments>https://news.ycombinator.com/item?id=41</comments>'
               b'<description>&lt;a href="https://news.ycombinator.com/item?id=41"&gt;Comments&lt;/a&gt;</description></item></channel></rss>')


def thread():
    """The thread, with ages counted from now, as the comments show them."""
    now = int(time.time())
    return json.dumps({"id": 41, "type": "story", "children": [
        {"id": 1, "type": "comment", "author": "ann", "created_at_i": now - 7200,
         "text": "<p>This boots faster than I expected.<p>Has anyone tried it with <i>networking</i>?",
         "children": [{"id": 2, "type": "comment", "author": "bo", "created_at_i": now - 3600,
                       "text": "Yes, through a <a href=\"https://example.org/proxy\">WebSocket proxy</a>.", "children": []}]},
        {"id": 3, "type": "comment", "author": None, "text": None, "children": [
            {"id": 4, "type": "comment", "author": "cy", "created_at_i": now - 600, "text": "Still here.", "children": []}]}]}).encode()


# A custom theme the theme checks create.
DUSK = {"id": "dusk", "name": "Dusk", "base": "dark", "tokens": {"ground": "#1C1B29"}, "fonts": {"reading": "Georgia"}}

thread_requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_GET(self):
        body, kind = FEED, "application/rss+xml"
        if self.path == "/thread.xml":
            body = THREAD_FEED
        elif self.path.startswith("/items/"):
            thread_requests.append(self.path)
            body, kind = thread(), "application/json"
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)


def serve():
    """Starts the feed server on a free port and returns its base URL."""
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


def environment(home, fyke, base):
    """What the daemon and the app need, beyond the caller's own environment."""
    writer = pathlib.Path(home) / "writer.py"
    writer.write_text(WRITER_SOURCE)
    return {"FYKE_HOME": str(home), "FYKE_BIN": str(fyke), "FYKE_WRITER_CMD": f"{sys.executable} {writer}",
            "FYKE_HN_ITEMS_URL": f"{base}/items/"}


def prepare(fyke, env, base, timeout=60):
    """Adds the local feed and waits until the daemon holds its three articles. The
    daemon starts with the first command and fetches a new feed in the background; a
    cold start after a rebuild is slow, so this waits for the articles, not a fixed time.
    Returns a problem, or None."""
    def run(*args):
        return subprocess.run([str(fyke), *args], env=env, capture_output=True, text=True, timeout=60, check=True).stdout
    run("add", f"{base}/feed.xml", "--allow-private")
    deadline = time.monotonic() + timeout
    while len(json.loads(run("list", "--json"))["items"]) < 3:
        if time.monotonic() > deadline:
            return f"the feed was not fetched within {timeout} s"
        time.sleep(0.1)
    return None


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--home", required=True)
    parser.add_argument("--fyke", required=True)
    args = parser.parse_args()
    pathlib.Path(args.home).mkdir(parents=True, exist_ok=True)
    base = serve()
    extra = environment(args.home, args.fyke, base)
    problem = prepare(args.fyke, dict(os.environ, **extra), base)
    if problem:
        sys.exit(problem)
    print(json.dumps({"base": base, "env": extra}), flush=True)
    sys.stdin.read()


if __name__ == "__main__":
    main()

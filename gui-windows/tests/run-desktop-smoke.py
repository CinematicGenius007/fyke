"""Serve a local article fixture while the Windows desktop smoke test runs."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
from threading import Event, Thread

early_image_request = Event()
automatic_images_enabled = Event()
automatic_image_request = Event()
feed_updated = Event()
discovery_updated = Event()
discussion_enabled = Event()
discussion_too_early = Event()
discussion_failed_once = Event()


class Fixture(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/advance":
            feed_updated.set()
        elif self.path == "/advance-discovery":
            discovery_updated.set()
        elif self.path == "/enable-discussion":
            discussion_enabled.set()
        elif self.path == "/enable-automatic-images":
            automatic_images_enabled.set()
        else:
            self.send_error(404)
            return
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path == "/fixture.png":
            if automatic_images_enabled.is_set():
                automatic_image_request.set()
            else:
                early_image_request.set()
            self.send_error(404)
            return
        if self.path == "/image-status":
            self.send_body(b"requested" if automatic_image_request.is_set() else b"waiting", "text/plain")
            return
        if self.path == "/items/46001":
            self.serve_discussion()
            return
        if self.path == "/subscribe":
            page = b"""<!doctype html><html><head>
            <link rel="alternate" type="application/rss+xml" title="Discovery feed" href="/subscribe/first">
            <link rel="alternate" type="application/rss+xml" title="Other discovered feed" href="/subscribe/second">
            </head><body>Feeds</body></html>"""
            self.send_body(page, "text/html")
            return
        if self.path in ("/subscribe/first", "/subscribe/second"):
            first = self.path.endswith("/first")
            name = "Discovery feed" if first else "Other discovered feed"
            title = "First discovered article" if first else "Other discovered article"
            update = (
                '<item><title>Updated discovery article</title><guid>discovery-update</guid></item>'
                if first and discovery_updated.is_set()
                else ""
            )
            self.send_body(
                f'<rss version="2.0"><channel><title>{name}</title>'
                f'<item><title>{title}</title><guid>{self.path}</guid></item>{update}</channel></rss>'.encode(),
                "application/rss+xml",
            )
            return
        if self.path != "/feed":
            self.send_error(404)
            return

        port = self.server.server_address[1]
        update = (
            '<item><title>Live reader update</title><guid isPermaLink="false">reader-update</guid>'
            '<comments>https://example.test/discussion</comments>'
            '<description>Arrives while the first article is open.</description></item>'
            if feed_updated.is_set()
            else ""
        )
        body = f"""<rss version="2.0"><channel><title>Desktop fixture</title>
        <item><title>Native reader fixture</title><guid isPermaLink="false">reader-fixture</guid>
        <comments>https://news.ycombinator.com/item?id=46001</comments>
        <description><![CDATA[<p>The story is rendered from stored blocks.</p>
        <p><img src="http://127.0.0.1:{port}/fixture.png" alt="Fixture illustration"></p>]]>
        </description></item>{update}</channel></rss>""".encode()
        self.send_body(body, "application/rss+xml")

    def serve_discussion(self):
        if not discussion_enabled.is_set():
            discussion_too_early.set()
            self.send_error(503)
            return
        if not discussion_failed_once.is_set():
            discussion_failed_once.set()
            self.send_error(503)
            return
        thread = {
            "children": [{
                "id": 46002, "type": "comment", "author": "first-reader", "text": "<p>A native comment.</p>",
                "children": [{
                    "id": 46003, "type": "comment", "author": "second-reader", "text": "<p>A nested reply.</p>",
                    "children": [],
                }],
            }],
        }
        self.send_body(json.dumps(thread).encode(), "application/json")

    def send_body(self, body, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    app, daemon = map(lambda path: str(Path(path).resolve(strict=True)), sys.argv[1:])
    script = Path(__file__).with_name("desktop-smoke.ps1")
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        worker = Thread(target=server.serve_forever)
        worker.start()
        try:
            base = f"http://127.0.0.1:{server.server_address[1]}"
            subprocess.run(
                [
                    "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                    "-File", str(script), "-App", app, "-Daemon", daemon, "-FeedUrl", base + "/feed",
                ],
                check=True,
                timeout=240,
                env=dict(os.environ, FYKE_HN_ITEMS_URL=base + "/items/"),
            )
            if early_image_request.is_set():
                raise RuntimeError("The reader fetched an image before automatic loading was enabled.")
            if not automatic_image_request.is_set():
                raise RuntimeError("The reader did not fetch the image after automatic loading was enabled.")
            if discussion_too_early.is_set():
                raise RuntimeError("The reader fetched a discussion before the user requested it.")
        finally:
            server.shutdown()
            worker.join()


if __name__ == "__main__":
    main()

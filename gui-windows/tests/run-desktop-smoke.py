"""Serve a local article fixture while the Windows desktop smoke test runs."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
from threading import Event, Thread

image_requested = Event()
feed_updated = Event()


class Fixture(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/advance":
            self.send_error(404)
            return
        feed_updated.set()
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path == "/fixture.png":
            image_requested.set()
        if self.path != "/feed":
            self.send_error(404)
            return

        port = self.server.server_address[1]
        update = (
            '<item><title>Live reader update</title><guid isPermaLink="false">reader-update</guid>'
            '<description>Arrives while the first article is open.</description></item>'
            if feed_updated.is_set()
            else ""
        )
        body = f"""<rss version="2.0"><channel><title>Desktop fixture</title>
        <item><title>Native reader fixture</title><guid isPermaLink="false">reader-fixture</guid>
        <description><![CDATA[<p>The story is rendered from stored blocks.</p>
        <p><img src="http://127.0.0.1:{port}/fixture.png" alt="Fixture illustration"></p>]]>
        </description></item>{update}</channel></rss>""".encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/rss+xml")
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
            url = f"http://127.0.0.1:{server.server_address[1]}/feed"
            subprocess.run(
                [
                    "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                    "-File", str(script), "-App", app, "-Daemon", daemon, "-FeedUrl", url,
                ],
                check=True,
                timeout=240,
            )
            if image_requested.is_set():
                raise RuntimeError("The reader fetched a remote image before the user requested it.")
        finally:
            server.shutdown()
            worker.join()


if __name__ == "__main__":
    main()

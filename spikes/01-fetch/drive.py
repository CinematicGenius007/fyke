#!/usr/bin/env python3
"""Spike driver: runs fetchone per feed, compares every failure against curl.

Usage: drive.py <fetchone-binary> <smallweb.txt> <results.jsonl>
One process per feed so that a crash or hang is a recorded result, not a lost run.
"""
import concurrent.futures as cf, json, random, subprocess, sys

BIG = """https://www.nasa.gov/rss/dyn/breaking_news.rss
https://feeds.bbci.co.uk/news/rss.xml
https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml
https://www.theguardian.com/world/rss
https://feeds.arstechnica.com/arstechnica/index
https://www.theverge.com/rss/index.xml
https://techcrunch.com/feed/
https://www.wired.com/feed/rss
https://hnrss.org/frontpage
https://lobste.rs/rss
https://www.reddit.com/r/programming/.rss
https://github.com/ziglang/zig/releases.atom
https://github.blog/feed/
https://blog.cloudflare.com/rss/
https://aws.amazon.com/blogs/aws/feed/
https://stackoverflow.blog/feed/
https://medium.com/feed/@netflixtechblog
https://www.youtube.com/feeds/videos.xml?channel_id=UCsBjURrPoezykLs9EqgamOA
https://simonwillison.net/atom/everything/
https://jvns.ca/atom.xml
https://danluu.com/atom.xml
https://www.joelonsoftware.com/feed/
https://xkcd.com/atom.xml
https://www.smashingmagazine.com/feed/
https://css-tricks.com/feed/
https://daringfireball.net/feeds/main
https://www.schneier.com/feed/atom/
https://krebsonsecurity.com/feed/
https://feeds.npr.org/1001/rss.xml
https://www.jsonfeed.org/feed.json""".split()

binary, smallweb, out_path = sys.argv[1:4]
urls = [u.strip() for u in open(smallweb) if u.strip().startswith("http")]
random.seed(20261106)
targets = [("big", u) for u in BIG] + [("smallweb", u) for u in random.sample(urls, 170)]

def run_zig(url, etag="", lm=""):
    try:
        p = subprocess.run([binary, url, etag, lm], capture_output=True, text=True, timeout=30, errors="replace")
    except subprocess.TimeoutExpired:
        return {"outcome": "hang"}
    if p.returncode == 0 and p.stdout.strip():
        return {"outcome": "ok", **json.loads(p.stdout)}
    tail = p.stderr.strip().splitlines()
    return {"outcome": "crash" if p.returncode < 0 else "error", "rc": p.returncode,
            "err": tail[0][:160] if tail else ""}

def run_curl(url):
    p = subprocess.run(["curl", "-sSL", "--compressed", "--max-time", "30", "-o", "/dev/null",
                        "-A", "rss_-spike/0.1 (feed reader prototype)",
                        "-w", "%{http_code} %{size_download}", url], capture_output=True, text=True)
    return {"rc": p.returncode, "out": p.stdout, "err": p.stderr.strip()[:160]}

def one(item):
    group, url = item
    r = {"group": group, "url": url, "first": run_zig(url), "curl": run_curl(url)}
    f = r["first"]
    if f.get("status") == 200 and (f.get("etag") or f.get("last_modified")):
        r["second"] = run_zig(url, f.get("etag", ""), f.get("last_modified", ""))
    return r

with cf.ThreadPoolExecutor(12) as pool, open(out_path, "w") as out:
    for r in pool.map(one, targets):
        out.write(json.dumps(r) + "\n"); out.flush()

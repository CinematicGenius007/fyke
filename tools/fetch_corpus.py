#!/usr/bin/env python3
"""Downloads real feeds into corpus/ for parser testing. The corpus is third-party
content, so it stays out of version control and is rebuilt with this script.

Usage: fetch_corpus.py <smallweb.txt> [count]
smallweb.txt comes from https://github.com/kagisearch/smallweb
"""
import concurrent.futures as cf, hashlib, os, random, subprocess, sys

EXTRA = """https://feeds.bbci.co.uk/news/rss.xml
https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml
https://www.theguardian.com/world/rss
https://feeds.arstechnica.com/arstechnica/index
https://www.theverge.com/rss/index.xml
https://techcrunch.com/feed/
https://www.wired.com/feed/rss
https://hnrss.org/frontpage
https://lobste.rs/rss
https://github.com/ziglang/zig/releases.atom
https://github.blog/feed/
https://blog.cloudflare.com/rss/
https://aws.amazon.com/blogs/aws/feed/
https://stackoverflow.blog/feed/
https://medium.com/feed/@netflixtechblog
https://simonwillison.net/atom/everything/
https://jvns.ca/atom.xml
https://danluu.com/atom.xml
https://xkcd.com/atom.xml
https://www.smashingmagazine.com/feed/
https://daringfireball.net/feeds/main
https://daringfireball.net/feeds/json
https://www.schneier.com/feed/atom/
https://krebsonsecurity.com/feed/
https://feeds.npr.org/1001/rss.xml
https://www.jsonfeed.org/feed.json
https://www.w3.org/blog/news/feed/rdf
https://slashdot.org/index.rdf
https://rss.slashdot.org/Slashdot/slashdotMain
https://www.heise.de/rss/heise-atom.xml
https://www.spiegel.de/schlagzeilen/index.rss
https://www.lemonde.fr/rss/une.xml
https://elpais.com/rss/elpais/portada.xml
https://www3.nhk.or.jp/rss/news/cat0.xml
https://www.asahi.com/rss/asahi/newsheadlines.rdf
https://feeds.megaphone.fm/vergecast
https://feeds.simplecast.com/54nAGcIl""".split()

smallweb, count = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 750
os.makedirs("corpus", exist_ok=True)
urls = [u.strip() for u in open(smallweb) if u.strip().startswith("http")]
random.seed(1)
targets = EXTRA + random.sample(urls, count)

def get(url):
    name = hashlib.sha1(url.encode()).hexdigest()[:16] + ".feed"
    path = os.path.join("corpus", name)
    p = subprocess.run(["curl", "-sSL", "--compressed", "--max-time", "20", "--max-filesize", "33554432",
                        "-A", "rss_/0.1 (feed reader in development)", "-o", path,
                        "-w", "%{http_code}\t%{content_type}", url], capture_output=True, text=True)
    status, _, ctype = p.stdout.partition("\t")
    if p.returncode != 0 or status != "200":
        if os.path.exists(path): os.remove(path)
        return None
    return f"{name}\t{ctype}\t{url}\n"

with cf.ThreadPoolExecutor(10) as pool, open("corpus/index.tsv", "w") as index:
    for row in pool.map(get, targets):
        if row: index.write(row)

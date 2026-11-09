#!/usr/bin/env python3
"""Measures article extraction against a known answer. A feed that publishes full
articles gives the true text, so this fetches the page for one entry of each such
feed, extracts it, and compares the two.

Usage: feedcheck corpus --html-dump > html.jsonl
       eval_extract.py <feedcheck> <html.jsonl> <dump.jsonl> [count]
Sends one request per sampled feed. Pages are kept in corpus/pages.
"""
import collections, concurrent.futures as cf, hashlib, json, os, random, re, subprocess, sys, time

feedcheck, html_path, dump_path = sys.argv[1:4]
count = int(sys.argv[4]) if len(sys.argv) > 4 else 150
os.makedirs("corpus/pages", exist_ok=True)

urls = {}
for line in open(dump_path):
    row = json.loads(line)
    for e in row["entries"]:
        if e.get("content") and e["content"]["kind"] == "html" and e.get("url", "") and e["url"].startswith("http"):
            urls[e["content"]["value"]] = e["url"]

by_feed = collections.defaultdict(list)
for line in open(html_path):
    row = json.loads(line)
    if len(row["text"]) >= 1500 and row["html"] in urls:
        by_feed[row["name"]].append((urls[row["html"]], row["text"]))
random.seed(5)
sample = [random.choice(v) for v in by_feed.values()]
random.shuffle(sample)
sample = sample[:count]

def get(item):
    url, text = item
    path = "corpus/pages/" + hashlib.sha1(url.encode()).hexdigest()[:16] + ".html"
    if not os.path.exists(path):
        r = subprocess.run(["curl", "-sSL", "--compressed", "--max-time", "20", "-A", "fyke/0.1 (feed reader)", "-o", path, "-w", "%{http_code}", url], capture_output=True, text=True)
        if r.stdout != "200":
            if os.path.exists(path): os.remove(path)
            return None
    return url, text, path

with cf.ThreadPoolExecutor(6) as pool:
    fetched = [r for r in pool.map(get, sample) if r]

def words(text):
    return collections.Counter(re.findall(r"\w+", text.lower()))

rows = []
for url, truth, path in fetched:
    p = subprocess.run([feedcheck, "--extract", path, url], capture_output=True, text=True, errors="replace", timeout=30)
    got = words(p.stdout); want = words(truth)
    total = sum(want.values()); size = sum(got.values())
    recall = sum((want & got).values()) / max(total, 1)
    precision = sum((want & got).values()) / max(size, 1)
    rows.append((recall, precision, size, total, url))

n = len(rows)
found = [r for r in rows if r[2] > 0]
print(f"sampled {len(sample)}, fetched {n}, extraction found something in {len(found)}")
def pct(values, q):
    values = sorted(values); return values[min(len(values) - 1, int(len(values) * q))]
print("recall    p10 %.3f  p50 %.3f" % (pct([r[0] for r in found], .1), pct([r[0] for r in found], .5)))
print("precision p10 %.3f  p50 %.3f" % (pct([r[1] for r in found], .1), pct([r[1] for r in found], .5)))
good = sum(1 for r in found if r[0] >= .9 and r[1] >= .8)
print(f"good (recall >= 0.9, precision >= 0.8): {good} of {n}")
for r in sorted(rows, key=lambda r: min(r[0], r[1]))[:14]:
    print(f"  recall {r[0]:.2f} precision {r[1]:.2f} got {r[2]} want {r[3]} {r[4][:70]}")

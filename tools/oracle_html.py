#!/usr/bin/env python3
"""Cross-checks HTML conversion against Python's html.parser on the corpus, and
scans stored blocks for anything that should be impossible.

Usage: feedcheck corpus --html-dump > html.jsonl; oracle_html.py html.jsonl
"""
import collections, html.parser, json, re, sys

SKIP = {"script", "style", "noscript", "template", "svg", "math", "head", "title", "form", "select",
        "textarea", "button", "canvas", "nav", "object", "iframe", "video", "audio", "embed"}
VOID = {"img", "br", "hr", "meta", "link", "input", "source", "wbr", "area", "base", "col", "track"}

class Text(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.words = []; self.skip = 0
    def handle_starttag(self, tag, attrs):
        if tag in SKIP: self.skip += 1
        if tag == "img":
            alt = dict(attrs).get("alt")
            src = dict(attrs).get("src") or ""
            a = dict(attrs)
            pixel = a.get("width") in ("0", "1") and a.get("height") in ("0", "1")
            if alt and not self.skip and not pixel and not src.startswith("data:"): self.words += alt.split()
    def handle_endtag(self, tag):
        if tag in SKIP and self.skip: self.skip -= 1
    def handle_data(self, data):
        if not self.skip: self.words += data.split()

def words(text):
    return collections.Counter(re.findall(r"\w+", text.lower()))

bodies = safe = 0
ratios = []; worst = []; unsafe = collections.Counter()
for line in open(sys.argv[1]):
    row = json.loads(line)
    bodies += 1
    parser = Text()
    parser.feed(row["html"]); parser.close()
    want = words(" ".join(parser.words)); got = words(row["text"])
    total = sum(want.values())
    if total >= 5:
        missing = sum((want - got).values()) / total
        extra = sum((got - want).values()) / total
        ratios.append(max(missing, extra))
        if max(missing, extra) > 0.02:
            lost = " ".join(w for w, _ in (want - got).most_common(6))
            worst.append((round(max(missing, extra), 3), round(missing, 3), round(extra, 3), row["name"], lost, row["html"][:60]))
    blocks = row["blocks"]
    for pattern, label in ((r'"href":"\s*(javascript|data|vbscript):', "bad link"), (r'"src":"\s*(javascript|data):', "bad image"),
                           (r'"t":"(script|style|iframe)"', "bad node"), (r"(?<!\\)\\u00(0[0-8bcef]|1[0-9a-f])", "control char")):
        if re.search(pattern, blocks, re.I): unsafe[label] += 1

ratios.sort()
n = len(ratios)
print(f"bodies {bodies}, compared {n}")
print(f"word difference: p50 {ratios[n//2]:.4f}, p95 {ratios[n*95//100]:.4f}, p99 {ratios[n*99//100]:.4f}, max {ratios[-1]:.4f}")
print(f"over 2% different: {len(worst)}")
print("unsafe content:", dict(unsafe) or "none")
for row in sorted(worst, reverse=True)[:12]: print(" ", row)

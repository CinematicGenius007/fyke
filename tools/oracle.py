#!/usr/bin/env python3
"""Cross-checks our parser against Python's strict XML parser on the corpus.

Usage: feedcheck corpus --dump > dump.jsonl; oracle.py corpus dump.jsonl
Only well-formed files can be compared, and only fields with an unambiguous reading.
"""
import collections, datetime, email.utils, html, json, os, re, sys
import xml.etree.ElementTree as ET

ATOM = "{http://www.w3.org/2005/Atom}"
RSS1 = "{http://purl.org/rss/1.0/}"
RSS09 = "{http://my.netscape.com/rdf/simple/0.9/}"

def norm(text):
    return (text or "").strip() or None

def child(el, *tags):
    for tag in tags:
        found = el.find(tag)
        if found is not None and len(found) == 0 and norm(found.text):
            return norm(found.text)
    return None

def xml_unescape(text):
    return html.unescape(text)

def rss_entries(root):
    out = []
    for item in [e for e in root.iter() if e.tag in ("item", RSS1 + "item", RSS09 + "item")]:
        out.append({"title": child(item, "title", RSS1 + "title", RSS09 + "title"),
                    "url": child(item, "link", RSS1 + "link", RSS09 + "link"),
                    "guid": child(item, "guid"),
                    "date": child(item, "pubDate")})
    return out

def atom_entries(root):
    out = []
    for entry in root.findall(ATOM + "entry"):
        link = None
        for l in entry.findall(ATOM + "link"):
            if l.get("rel", "alternate") == "alternate" and l.get("href"):
                link = l.get("href").strip(); break
        title = entry.find(ATOM + "title")
        plain = title is not None and title.get("type", "text") != "xhtml"
        text = norm(title.text) if plain else "?"
        # A title of type "html" is escaped a second time, for HTML.
        if plain and text and "html" in title.get("type", ""): text = norm(xml_unescape(text))
        out.append({"title": text, "url": link, "guid": child(entry, ATOM + "id"),
                    "date": child(entry, ATOM + "published")})
    return out

def expected_ms(text):
    if text is None: return None
    # parsedate_tz, because parsedate_to_datetime reads "-0000" as local time.
    fixed = re.sub(r"([+-]\d\d):(\d\d)$", r"\1\2", text)
    parts = email.utils.parsedate_tz(fixed)
    if " 0001 " in text: return None  # Python reads this placeholder year as 2001.
    if parts is not None and parts[0] >= 1900:
        return email.utils.mktime_tz(parts) * 1000
    try:
        parsed = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None: parsed = parsed.replace(tzinfo=datetime.timezone.utc)
        return int(parsed.timestamp() * 1000)
    except ValueError:
        return None

corpus, dump_path = sys.argv[1:3]
ours = {}
for line in open(dump_path):
    row = json.loads(line); ours[row["name"]] = row

stats = collections.Counter(); problems = collections.Counter(); samples = {}
for name, row in ours.items():
    if row["format"].startswith("json"): continue
    # ElementTree expands internal entities, so a downloaded bomb would hang this check.
    if b"<!ENTITY" in open(os.path.join(corpus, name), "rb").read():
        stats["declares entities, skipped by oracle"] += 1
        continue
    try:
        root = ET.parse(os.path.join(corpus, name)).getroot()
    except (ET.ParseError, ValueError):
        stats["malformed, skipped by oracle"] += 1
        continue
    stats["compared feeds"] += 1
    expected = atom_entries(root) if row["format"].startswith("atom") else rss_entries(root)
    got = row["entries"]
    if len(expected) != len(got):
        problems["entry count"] += 1
        samples.setdefault("entry count", (name, len(expected), len(got)))
        continue
    for e, g in zip(expected, got):
        stats["compared entries"] += 1
        for field in ("title", "url", "guid"):
            if e[field] is None or e[field] == "?": continue
            stats["compared " + field] += 1
            if e[field] != g.get(field):
                problems[field] += 1
                samples.setdefault(field, (name, e[field][:70], (g.get(field) or "")[:70]))
        want = expected_ms(e["date"])
        if want is not None:
            stats["compared date"] += 1
            if want != g.get("published_at"):
                problems["date"] += 1
                samples.setdefault("date", (name, e["date"], want, g.get("published_at")))

for key, value in sorted(stats.items()): print(f"{key}: {value}")
print("mismatches:", dict(problems) or "none")
for key, value in samples.items(): print(" ", key, value)

#!/usr/bin/env python3
"""Summarizes results.jsonl from drive.py."""
import collections, json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
C = collections.Counter
print("feeds", len(rows))
print("zig outcome", C(r["first"]["outcome"] for r in rows))
print("zig status", sorted(C(r["first"].get("status") for r in rows if r["first"]["outcome"] == "ok").items()))
curl_status = lambda r: r["curl"]["out"].split(" ")[0] if r["curl"]["out"] else ""
curl_ok = lambda r: r["curl"]["rc"] == 0 and curl_status(r) == "200"
zig_ok = lambda r: r["first"].get("status") == 200
print("curl 200:", sum(map(curl_ok, rows)), " zig 200:", sum(map(zig_ok, rows)),
      " both:", sum(curl_ok(r) and zig_ok(r) for r in rows))
print("encoding", C(r["first"].get("encoding") for r in rows if zig_ok(r)))
print("redirected", sum(r["first"].get("hops", 0) > 0 for r in rows), "permanent", sum(bool(r["first"].get("permanent")) for r in rows))
print("second-pass", C(r["second"].get("status", r["second"]["outcome"]) for r in rows if "second" in r))
print("\nzig failed where curl got 200:")
gap = [r for r in rows if curl_ok(r) and not zig_ok(r)]
for k, n in C((r["first"]["outcome"], r["first"].get("status"), r["first"].get("err", "")) for r in gap).most_common():
    print(" ", n, k)
for r in gap: print("   ", r["url"])
print("\nzig got 200 where curl did not:", [r["url"] for r in rows if zig_ok(r) and not curl_ok(r)])

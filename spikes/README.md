# Spikes

Throwaway code that tested the riskiest assumptions before committing to the language. Nothing here is production code. Results are in [docs/decisions/0001-language.md](../docs/decisions/0001-language.md#spike-results).

Run with Zig 0.17.1, Swift 6.4, on Apple silicon.

## 01-fetch

```bash
zig build-exe fetchone.zig -OReleaseSafe
zig build-exe fetchmany.zig -OReleaseSafe
python3 drive.py ./fetchone smallweb.txt results.jsonl
python3 report.py results.jsonl
./fetchmany urls.txt 16 15
```

`smallweb.txt` is [Kagi's small web list](https://github.com/kagisearch/smallweb). `drive.py` runs one process per feed and compares each result against curl. `fetchmany` is the shape the daemon needs: one process, a shared client, per-feed deadlines.

## 02-sqlite

Needs the SQLite amalgamation in `vendor/`. Copy it from `../../vendor/sqlite/`.

```bash
zig build -Drelease
./zig-out/bin/bench /path/to/test.db ../../schema/0001_init.sql 1000000
```

## 03-swiftui

`server.zig` is a stand-in daemon with synthetic rows. The socket path must fit the 104-byte macOS limit, so run from a short path.

```bash
zig build-exe server.zig -OReleaseSafe
./server s.sock
swift build -c release
.build/release/ReaderSpike s.sock --bench
.build/release/ReaderSpike s.sock --scroll snapshot.png
```

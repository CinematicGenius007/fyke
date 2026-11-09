#!/usr/bin/env python3
"""Runs the end-to-end scripts against a Linux build, inside a Debian container.

    python3 tools/e2e_container.py            builds and runs everything
    python3 tools/e2e_container.py e2e_mcp    runs only the named scripts

It cross-compiles a static binary for the container's architecture, so what runs is
what a Linux release ships. The same steps are what continuous integration runs on a
Linux runner, minus Docker. Needs Docker and Zig.
"""
import pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
scripts = sys.argv[1:] or ["e2e", "e2e_daemon", "e2e_mcp", "e2e_service", "e2e_tui"]

arch = subprocess.run(["docker", "info", "--format", "{{.Architecture}}"], check=True, capture_output=True, text=True).stdout.strip()
target = {"aarch64": "aarch64-linux-musl", "arm64": "aarch64-linux-musl", "x86_64": "x86_64-linux-musl"}[arch]

work = pathlib.Path(tempfile.mkdtemp(prefix="fyke-container-"))
try:
    print(f"building {target}", flush=True)
    subprocess.run(["zig", "build", "-Drelease", f"-Dtarget={target}", "--prefix", str(work / "out")], cwd=root, check=True)
    shutil.copy(work / "out/bin/fyke", work / "fyke")
    (work / "run.sh").write_text("""#!/bin/sh
# lsof: the daemon test finds the process holding the lock. pyte: the terminal test.
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq lsof procps >/dev/null 2>&1
pip install -q pyte >/dev/null 2>&1
status=0
for t in "$@"; do
  echo "=== $t"
  python3 /tools/$t.py /work/fyke > /work/$t.log 2>&1 || status=1
  tail -n 3 /work/$t.log
  grep -E "^FAIL" /work/$t.log
done
exit $status
""")
    (work / "run.sh").chmod(0o755)
    code = subprocess.run(["docker", "run", "--rm", "-v", f"{work}:/work", "-v", f"{root / 'tools'}:/tools:ro",
                           "python:3.13-slim-bookworm", "/work/run.sh", *scripts]).returncode
finally:
    shutil.rmtree(work, ignore_errors=True)
sys.exit(code)

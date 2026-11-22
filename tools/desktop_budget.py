#!/usr/bin/env python3
"""Measures the Windows and Linux app against its size and speed budgets.

    desktop_budget.py --app PATH --fyke PATH [--package PATH ...] [--out FILE]

--app is the built app (Fyke.App.exe or fyke-app), --fyke the daemon beside it, and each
--package an installer or package built from them (setup.exe, .deb or .AppImage).
Measures:

  package_mb      each package's size, by kind (setup, deb, appimage)
  installed_mb    the program files: the app and the daemon
  cold_start_ms   launch to the first article list drawn, the median of three launches
  idle_memory_mb  memory the app and its web view processes hold on their own (USS)
                  a few seconds after that list draws

The app runs in test mode (FYKE_HEADLESS, FYKE_MEASURE: see desktop/src-tauri/src/
testmode.rs) against the GUI checks' data (tools/gui_fixtures.py) in a scratch
FYKE_HOME, so it never shows a window or touches real data. On Linux it needs a display;
CI runs it under xvfb-run.

The budgets are in desktop/budgets.json, a little above the first measurement on CI
(docs/desktop.md, "Size and speed"). Any figure over its budget fails the run. A change
that needs more must raise the budget and say why in its pull request.
"""
import argparse, json, os, pathlib, platform, shutil, statistics, subprocess, sys, tempfile, time

root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / "tools"))
import gui_fixtures  # noqa: E402

try:
    import psutil
except ImportError:
    sys.exit("desktop_budget.py needs psutil: python -m pip install psutil")

MB = 1024 * 1024
HOLD = 4.0  # seconds the app stays after it draws, for the memory reading


def system():
    return "windows" if os.name == "nt" else "linux" if sys.platform.startswith("linux") else platform.system().lower()


def package_kind(path):
    name = path.name.lower()
    if name.endswith(".exe"):
        return "setup"
    if name.endswith(".deb"):
        return "deb"
    if name.endswith(".appimage"):
        return "appimage"
    sys.exit(f"{path}: not a setup.exe, .deb or .AppImage")


def tree_memory(process):
    """The unique memory of a process and everything it started, in MB."""
    total = 0
    for each in [process, *process.children(recursive=True)]:
        try:
            info = each.memory_full_info()
            total += getattr(info, "uss", info.rss)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return total / MB


def launch(app, env):
    """Launches the app once. Returns (ms to the first list, idle memory in MB)."""
    started = time.perf_counter()
    child = subprocess.Popen([str(app)], env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        line = child.stdout.readline()
        elapsed = (time.perf_counter() - started) * 1000
        if line.strip() != "ready":
            sys.exit(f"the app did not report ready (exit {child.poll()}, said {line!r})")
        time.sleep(HOLD / 2)
        memory = tree_memory(psutil.Process(child.pid))
        child.wait(timeout=HOLD * 4)
        return elapsed, memory
    finally:
        if child.poll() is None:
            for each in psutil.Process(child.pid).children(recursive=True):
                each.kill()
            child.kill()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--fyke", required=True, type=pathlib.Path)
    parser.add_argument("--package", action="append", default=[], type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path)
    args = parser.parse_args()
    app, fyke = args.app.resolve(), args.fyke.resolve()

    figures = {"installed_mb": (app.stat().st_size + fyke.stat().st_size) / MB}
    for package in args.package:
        figures[f"package_mb.{package_kind(package)}"] = package.stat().st_size / MB

    scratch = pathlib.Path(tempfile.mkdtemp(prefix="fyke-budget-"))
    home = scratch / "data"
    home.mkdir()
    base = gui_fixtures.serve()
    env = dict(os.environ, **gui_fixtures.environment(home, fyke, base))
    try:
        problem = gui_fixtures.prepare(fyke, env, base)
        if problem:
            sys.exit(problem)
        runs = [launch(app, dict(env, FYKE_HEADLESS="1", FYKE_MEASURE=str(HOLD))) for _ in range(3)]
    finally:
        subprocess.run([str(fyke), "daemon", "stop"], env=env, capture_output=True, timeout=60)
        shutil.rmtree(scratch, ignore_errors=True)
    figures["cold_start_ms"] = statistics.median(ms for ms, _ in runs)
    figures["idle_memory_mb"] = statistics.median(mb for _, mb in runs)

    budgets = json.loads((root / "desktop" / "budgets.json").read_text())[system()]
    rows, over = [], []
    for name, value in figures.items():
        budget = budgets.get(name)
        ok = budget is None or value <= budget
        rows.append(f"| {name} | {value:.1f} | {'' if budget is None else budget} | {'ok' if ok else 'OVER'} |")
        if not ok:
            over.append(name)
    table = "\n".join([f"### Desktop budgets ({system()})", "", "| figure | measured | budget | |", "|---|---:|---:|---|", *rows, ""])
    print(table)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(table + "\n")
    if args.out:
        args.out.write_text(json.dumps({"system": system(), "figures": figures}, indent=2) + "\n")
    missing = [name for name in figures if name not in budgets]
    if missing:
        sys.exit(f"no budget for {', '.join(missing)} in desktop/budgets.json")
    if over:
        sys.exit(f"over budget: {', '.join(over)}")


if __name__ == "__main__":
    main()

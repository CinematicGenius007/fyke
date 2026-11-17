#!/usr/bin/env python3
"""Runs the checks that the changed files call for, instead of every suite.

    python3 tools/check.py                  files changed since main, committed or not
    python3 tools/check.py --since HEAD~3   files changed since another ref
    python3 tools/check.py --staged         only what is staged
    python3 tools/check.py --working        only uncommitted changes, staged or not
    python3 tools/check.py --all            every suite, for the end of a change
    python3 tools/check.py --dry-run        prints the plan and stops

The plan is printed before anything runs. The GUI checks run headless, so they do not
take the screen or focus from someone working at the Mac. Suites that need setup this
script cannot do, such as the parser oracles on a downloaded corpus, the conformance
suite or the Windows service check, are listed in AGENTS.md and are run by hand.
"""
import argparse, fnmatch, pathlib, shutil, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
FYKE = "./zig-out/bin/fyke"
APP = "./zig-out/Fyke.app"

# A suite is a name and the commands it runs. Order here is the order they run in:
# builds first, then the fast checks, then the slow ones.
SUITES = {
    "zig-test":    ["zig build test"],
    "zig-build":   ["zig build"],
    "e2e":         [f"python3 tools/e2e.py {FYKE}"],
    "e2e-daemon":  [f"python3 tools/e2e_daemon.py {FYKE}"],
    "e2e-mcp":     [f"python3 tools/e2e_mcp.py {FYKE}"],
    "e2e-features": [f"python3 tools/e2e_features.py {FYKE}"],
    "e2e-service": [f"python3 tools/e2e_service.py {FYKE}"],
    "e2e-tui":     [f".venv/bin/python tools/e2e_tui.py {FYKE}"],
    "swift-test":  ["swift test --package-path gui"],
    "swift-build": ["swift build --package-path gui"],
    "tokens":      ["python3 tools/gen_tokens.py --check"],
    "bundle":      ["python3 tools/bundle_app.py"],
    "gui":         [],  # filled with the e2e_gui.py names below
    "diagrams":    ["python3 tools/render_diagrams.py"],
    "site":        ["cd site && pnpm build"],
}

# Paths, as shell patterns, and what each calls for. A path takes every row it matches.
# GUI rows name e2e_gui.py checks or screens (see `e2e_gui.py --list`).
RULES = [
    # The pure modules: parsing and conversion. e2e.py fetches and parses real feeds.
    (["src/xml.zig", "src/html.zig", "src/feed.zig", "src/blocks.zig", "src/encoding.zig", "src/dates.zig",
      "src/extract.zig", "src/url.zig", "src/fuzz.zig"], ["zig-test", "e2e"], []),
    (["src/fetch.zig", "src/pipeline.zig", "src/robots.zig", "src/schedule.zig", "src/runner.zig", "src/opml.zig"],
     ["zig-test", "e2e", "e2e-daemon"], []),
    # The data model and the operations every surface shares.
    (["src/store.zig", "src/selector.zig", "src/features.zig", "src/ops.zig", "src/writer.zig", "schema/*.sql"],
     ["zig-test", "e2e-features", "e2e-mcp", "e2e-daemon"], ["keys", "view-save", "brief", "routine-save"]),
    (["src/daemon.zig", "src/client.zig", "src/main.zig", "src/root.zig", "src/data_home.zig", "src/data_move.zig", "src/platform.zig"],
     ["zig-test", "e2e", "e2e-daemon", "e2e-features"], ["keys", "move"]),
    (["src/mcp.zig"], ["zig-test", "e2e-mcp"], []),
    (["src/tui.zig", "src/terminal.zig", "src/console*.zig", "src/layout.zig", "src/width_table.zig"], ["zig-test", "e2e-tui"], []),
    (["src/service.zig", "src/launchd.zig", "src/systemd.zig", "src/autostart.zig", "src/windows_startup.zig"],
     ["zig-test", "e2e-service"], []),
    (["src/*", "build.zig", "build.zig.zon"], ["zig-test"], []),
    (["tools/e2e.py"], ["e2e"], []), (["tools/e2e_daemon.py"], ["e2e-daemon"], []), (["tools/e2e_mcp.py"], ["e2e-mcp"], []),
    (["tools/e2e_features.py"], ["e2e-features"], []), (["tools/e2e_service.py"], ["e2e-service"], []),
    (["tools/e2e_tui.py"], ["e2e-tui"], []), (["tools/bundle_app.py"], ["bundle"], ["keys"]),
    (["tools/e2e_gui.py"], [], ["snapshots", "keys"]),
    # The app. Pure logic has unit tests; each view file names the screens it draws.
    (["gui/Sources/ReaderLogic/*", "gui/Tests/*"], ["swift-test"], []),
    (["gui/tokens.css", "tools/gen_tokens.py", "gui/Fonts/*"], ["tokens"], ["snapshots"]),
    (["gui-windows/src/Fyke.App/Themes/Tokens.xaml"], ["tokens"], []),
    (["gui/Package.swift"], ["swift-test"], ["snapshots"]),
    (["gui/Sources/Reader/Activity.swift"], [], ["activity"]),
    (["gui/Sources/Reader/AddFeed.swift"], [], ["all"]),
    (["gui/Sources/Reader/AppModel.swift"], [], ["keys", "view-save", "catchup", "palette", "all"]),
    (["gui/Sources/Reader/Ask.swift"], [], ["ask"]),
    (["gui/Sources/Reader/Brief.swift"], [], ["today", "citation"]),
    (["gui/Sources/Reader/CatchUp.swift"], [], ["catchup"]),
    (["gui/Sources/Reader/CommandPalette.swift"], [], ["palette"]),
    (["gui/Sources/Reader/Controls.swift", "gui/Sources/Reader/Kit.swift"], [], ["all", "view", "routines", "settings", "themes"]),
    (["gui/Sources/Reader/Daemon.swift"], [], ["keys", "move"]),
    (["gui/Sources/Reader/Features.swift", "gui/Sources/Reader/Library.swift"], [], ["today", "view", "routines", "ask", "recipe"]),
    (["gui/Sources/Reader/Models.swift"], [], ["keys", "all", "today"]),
    (["gui/Sources/Reader/Prefs.swift", "gui/Sources/Reader/Theme.swift"], [], ["themes", "settings", "all"]),
    (["gui/Sources/Reader/ReaderApp.swift", "gui/Sources/Reader/TestMode.swift"], [], ["keys", "divider", "settings-agents", "all"]),
    (["gui/Sources/Reader/ReaderPane.swift", "gui/Sources/Reader/WebPane.swift"], [], ["view", "all"]),
    (["gui/Sources/Reader/RecipeView.swift"], [], ["recipe"]),
    (["gui/Sources/Reader/RootView.swift"], [], ["keys", "all", "view", "divider"]),
    (["gui/Sources/Reader/Routines.swift"], [], ["routines"]),
    (["gui/Sources/Reader/Search.swift"], [], ["search", "keys"]),
    (["gui/Sources/Reader/SettingsView.swift", "gui/Sources/Reader/StoragePane.swift"], [], ["settings", "move"]),
    (["gui/Sources/Reader/Sidebar.swift"], [], ["all", "view", "activity", "health"]),
    (["gui/Sources/Reader/Today.swift"], [], ["today"]),
    (["gui/Sources/Reader/Tokens.swift"], [], ["snapshots"]),
    (["gui/Sources/Reader/TokensPane.swift"], [], ["settings-tokens", "themes"]),
    (["gui/Sources/Reader/Undo.swift"], [], ["undo", "toast"]),
    (["gui/Sources/Reader/Views.swift"], [], ["view"]),
    # A new view file nobody has mapped yet gets every picture.
    (["gui/Sources/Reader/*"], [], []),
    # Words only. The site renders docs/, so its build is the check for both.
    (["docs/diagrams/*.mmd", "tools/render_diagrams.py"], ["diagrams"], []),
    (["docs/*", "site/*", "README.md"], ["site"], []),
]
UNMAPPED_VIEW = ["snapshots"]


def changed(arguments):
    def git(*command):
        return subprocess.run(["git", *command], cwd=root, check=True, capture_output=True, text=True).stdout.split("\n")
    if arguments.staged:
        files = git("diff", "--name-only", "--cached")
    elif arguments.working:
        files = git("diff", "--name-only", "HEAD") + git("ls-files", "--others", "--exclude-standard")
    else:
        base = git("merge-base", arguments.since, "HEAD")[0]
        files = git("diff", "--name-only", base) + git("ls-files", "--others", "--exclude-standard")
    return sorted({f for f in files if f})


def plan(files):
    """Suites and GUI names for the files, and for each, the first file that asked for it."""
    suites, screens, why = set(), set(), {}
    for path in files:
        rows = [(run, gui) for patterns, run, gui in RULES if any(fnmatch.fnmatch(path, p) for p in patterns)]
        if path.startswith("gui/Sources/Reader/"):
            # A view file takes its own row only; the catch-all row is for files not yet mapped.
            rows = rows[:1] if rows[0] != ([], []) else [([], UNMAPPED_VIEW)]
        if not rows:
            why.setdefault("(nothing)", path)
        for run, gui in rows:
            suites.update(run); screens.update(gui)
            for name in list(run) + [f"gui:{g}" for g in gui]:
                why.setdefault(name, path)
    if screens:
        # The app has to be built and bundled before its checks can open it.
        suites.update(["swift-build", "bundle", "gui"])
    if suites & {"e2e", "e2e-daemon", "e2e-mcp", "e2e-features", "e2e-service", "e2e-tui"}:
        suites.add("zig-build")
    return suites, screens, why


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--since", default="main", help="compare with this ref's merge base (default main)")
    source.add_argument("--staged", action="store_true", help="only staged changes")
    source.add_argument("--working", action="store_true", help="only uncommitted changes")
    source.add_argument("--all", action="store_true", help="every suite and every GUI check")
    parser.add_argument("--dry-run", action="store_true", help="print the plan and stop")
    parser.add_argument("--visible", action="store_true", help="pass --visible to e2e_gui.py")
    arguments = parser.parse_args()

    if arguments.all:
        suites = set(SUITES) - {"diagrams"}
        screens, why = None, {}
        print("plan: everything")
    else:
        files = changed(arguments)
        if not files:
            print("no changed files"); return 0
        suites, screens, why = plan(files)
        print(f"{len(files)} changed files")
        for name, path in sorted(why.items()):
            print(f"  {name:22} because of {path}")
        if not suites:
            print("nothing to run"); return 0

    gui = "python3 tools/e2e_gui.py" + (f" --only {','.join(sorted(screens))}" if screens else "") + (" --visible" if arguments.visible else "")
    commands = []
    for suite, run in SUITES.items():
        if suite not in suites:
            continue
        if suite == "e2e-tui" and not (root / ".venv/bin/python").exists():
            print("  e2e-tui skipped: no .venv; see the Python test dependencies in AGENTS.md")
            continue
        if suite == "site" and not shutil.which("pnpm"):
            print("  site skipped: pnpm is not installed")
            continue
        commands += [gui] if suite == "gui" else run
    print("\nwill run:")
    for command in commands:
        print(f"  {command}")
    if arguments.dry_run:
        return 0

    failed = []
    for command in commands:
        print(f"\n$ {command}", flush=True)
        if subprocess.run(command, shell=True, cwd=root).returncode != 0:
            failed.append(command)
    print()
    for command in commands:
        print(f"{'FAIL' if command in failed else 'ok  '} {command}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

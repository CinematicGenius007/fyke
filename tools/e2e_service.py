#!/usr/bin/env python3
"""Tests `fyke service` against a recording stand-in for the platform's service manager.

The real `launchctl` or `systemctl` is never run: a shell script first on PATH records
its arguments and keeps a flag file for "enabled". That checks what Fyke writes and
which commands it issues, on any machine and without touching the user's own agents.

Usage: e2e_service.py <path-to-fyke>
"""
import os, shutil, subprocess, sys, tempfile

FYKE = os.path.abspath(sys.argv[1])
LINUX = sys.platform.startswith("linux")
MACOS = sys.platform == "darwin"
if not (LINUX or MACOS):
    print("service tests run on macOS and Linux only"); sys.exit(0)

root = tempfile.mkdtemp(prefix="fyke-s-", dir="/tmp")
user = root + "/home"; shim = root + "/bin"; log = root + "/calls.log"; flag = root + "/enabled"
os.makedirs(user); os.makedirs(shim)
manager = "systemctl" if LINUX else "launchctl"
# Query commands answer from the flag. Commands that change state set or clear it.
set_words = ("enable", "bootstrap")
clear_words = ("disable", "bootout")
query_words = ("is-enabled", "print")
with open(f"{shim}/{manager}", "w") as f:
    f.write(f"""#!/bin/sh
echo "$@" >> '{log}'
for a in "$@"; do
  [ "$a" = "$SHIM_FAIL" ] && exit 1
  case "$a" in
    {"|".join(set_words)}) touch '{flag}'; exit 0;;
    {"|".join(clear_words)}) rm -f '{flag}'; exit 0;;
    {"|".join(query_words)}) [ -f '{flag}' ]; exit $?;;
  esac
done
exit 0
""")
os.chmod(f"{shim}/{manager}", 0o755)

env = dict(os.environ, HOME=user, PATH=shim + ":" + os.environ["PATH"], FYKE_HOME=user + "/.fyke")
env.pop("XDG_CONFIG_HOME", None)
passed = 0
def check(name, ok, detail=""):
    global passed
    if not ok:
        print("FAIL", name, detail); shutil.rmtree(root, ignore_errors=True); sys.exit(1)
    passed += 1; print("ok  ", name)
def fyke(*args, env=env):
    return subprocess.run([FYKE, *args], env=env, capture_output=True, text=True, timeout=60)
def calls():
    return open(log).read().splitlines() if os.path.exists(log) else []

unit = f"{user}/.config/systemd/user/fyke.service" if LINUX else f"{user}/Library/LaunchAgents/local.fyke.daemon.plist"

p = fyke("service", "status")
check("not installed at first", p.returncode == 0 and p.stdout.strip() == "not installed", p.stdout + p.stderr)
check("status changes nothing", not os.path.exists(unit))

p = fyke("service", "install")
check("install succeeds", p.returncode == 0 and "installed" in p.stdout, p.stdout + p.stderr)
text = open(unit).read() if os.path.exists(unit) else ""
check("the definition is written where the platform looks", text != "", unit)
check("it runs this binary with the daemon arguments", FYKE in text and "daemon" in text and "--log" in text, text)
check("it names the data folder", user + "/.fyke" in text, text)
check("a clean stop is not restarted, a crash is",
      ("Restart=on-failure" in text) if LINUX else ("<key>SuccessfulExit</key><false/>" in text), text)
if LINUX:
    check("it starts with the person's session", "WantedBy=default.target" in text, text)
    check("systemd is told to reload, enable and restart, in order",
          calls()[-3:] == ["--user daemon-reload", "--user enable fyke.service", "--user restart fyke.service"], calls())
else:
    check("launchd is told to replace and load the agent",
          [c.split()[0] for c in calls()[-2:]] == ["bootout", "bootstrap"], calls())

p = fyke("service", "status")
check("status reports installed", p.stdout.strip() == "installed", p.stdout + p.stderr)

p = fyke("service", "install")
check("installing twice is fine", p.returncode == 0 and os.path.exists(unit), p.stdout + p.stderr)

if LINUX:
    other = root + "/xdg"
    p = fyke("service", "install", env=dict(env, XDG_CONFIG_HOME=other))
    check("XDG_CONFIG_HOME is respected", p.returncode == 0 and os.path.exists(other + "/systemd/user/fyke.service"), p.stdout + p.stderr)
    shutil.rmtree(other)
    # A path that needs escaping must survive: a space, a quote, a percent and a dollar sign.
    odd = root + '/we ird"%$'
    os.makedirs(odd); shutil.copy(FYKE, odd + "/fyke")
    p = subprocess.run([odd + "/fyke", "service", "install"], env=env, capture_output=True, text=True, timeout=60)
    text = open(unit).read()
    check("an unusual binary path is quoted and escaped", p.returncode == 0 and 'we ird\\"%%$$' in text, text)
    p = fyke("service", "install")  # leave the real path in place
    bare = root + "/emptybin"; os.makedirs(bare)
    p = fyke("service", "status", env=dict(env, PATH=bare))
    check("a machine without systemd gets a plain error", p.returncode != 0 and "SystemdMissing" in p.stderr, p.stderr)

if LINUX:
    before = len(calls())
    p = fyke("service", "install", env=dict(env, SHIM_FAIL="show-environment"))
    check("install stops early when there is no user service manager", p.returncode != 0 and "NoUserServiceManager" in p.stderr, p.stdout + p.stderr)
    check("and issues nothing else", calls()[before:] == ["--user show-environment"], calls()[before:])
    p = fyke("service", "uninstall", env=dict(env, SHIM_FAIL="disable"))
    check("a failed disable is reported and the definition stays", p.returncode != 0 and os.path.exists(unit), p.stdout + p.stderr)
if MACOS:
    legacy_plist = f"{user}/Library/LaunchAgents/local.rss_.daemon.plist"
    open(legacy_plist, "w").write("<plist/>")
    before = len(calls())
    p = fyke("service", "install")
    check("an agent installed under the earlier name is unloaded and removed",
          p.returncode == 0 and not os.path.exists(legacy_plist) and any("local.rss_.daemon" in c and c.startswith("bootout") for c in calls()[before:]), calls()[before:])

p = fyke("service", "uninstall")
check("uninstall succeeds", p.returncode == 0, p.stdout + p.stderr)
check("the definition is removed", not os.path.exists(unit))
p = fyke("service", "status")
check("status reports not installed again", p.stdout.strip() == "not installed", p.stdout + p.stderr)
p = fyke("service", "uninstall")
check("uninstalling twice is fine", p.returncode == 0, p.stdout + p.stderr)
check("an unknown action is a usage error", fyke("service", "nonsense").returncode == 2)

fyke("daemon", "stop")
shutil.rmtree(root, ignore_errors=True)
print(f"\n{passed} checks passed")

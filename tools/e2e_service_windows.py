#!/usr/bin/env python3
"""Tests `fyke service` on Windows against the real `Run` key of the current user.

Unlike the macOS and Linux test, there is no service manager to stand in for: the
service is one registry value, so this reads and writes the real one. A value named
Fyke that is already there belongs to a real installation, and the test refuses to
replace it unless CI is set.

Usage: e2e_service_windows.py <path-to-fyke.exe>
"""
import os, shutil, subprocess, sys, tempfile, time

if os.name != "nt":
    print("this test runs on Windows only"); sys.exit(0)

FYKE = os.path.abspath(sys.argv[1])
KEY = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
root = tempfile.mkdtemp(prefix="fyke-s-")
home = root + r"\data"
env = dict(os.environ, FYKE_HOME=home)

def reg(*args):
    return subprocess.run(["reg", *args], capture_output=True, text=True, timeout=30)
def value():
    p = reg("query", KEY, "/v", "Fyke")
    return p.stdout if p.returncode == 0 else None
def fyke(*args):
    return subprocess.run([FYKE, *args], env=env, capture_output=True, text=True, timeout=60)

if value() is not None and not os.environ.get("CI"):
    print("a Fyke entry is already in the Run key; refusing to replace it outside CI"); sys.exit(2)

passed = 0
def check(name, ok, detail=""):
    global passed
    if not ok:
        print("FAIL", name, detail)
        cleanup(); sys.exit(1)
    passed += 1; print("ok  ", name)
def daemons():
    """The fyke processes serving this test's folder, as {pid: command line}."""
    script = ("Get-CimInstance Win32_Process -Filter \"Name='fyke.exe'\" | "
              "ForEach-Object { \"$($_.ProcessId)`t$($_.CommandLine)\" }")
    p = subprocess.run(["powershell", "-NoProfile", "-Command", script], capture_output=True, text=True, timeout=60)
    found = {}
    for line in p.stdout.splitlines():
        pid, _, command = line.partition("\t")
        if home.lower() in command.lower():
            found[int(pid)] = command
    return found
def wait_for(predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        found = predicate()
        if found: return found
        time.sleep(0.2)
    return None
def cleanup():
    fyke("daemon", "stop")
    reg("delete", KEY, "/v", "Fyke", "/f")
    shutil.rmtree(root, ignore_errors=True)

p = fyke("service", "status")
check("not installed at first", p.returncode == 0 and p.stdout.strip() == "not installed", p.stdout + p.stderr)

p = fyke("service", "install")
check("install succeeds", p.returncode == 0 and "installed" in p.stdout, p.stdout + p.stderr)
text = value() or ""
check("the value is in the Run key", text != "", text)
check("it runs this binary under the supervisor", FYKE.lower() in text.lower() and " daemon --supervise --log " in text, text)
check("it names the data folder", home.lower() in text.lower(), text)
check("the daemon is running now", os.path.exists(home + r"\fyked.sock") or fyke("status").returncode == 0)

running = daemons()
supervisors = [pid for pid, command in running.items() if " --supervise " in command]
children = [pid for pid, command in running.items() if " --supervise " not in command]
check("a supervisor runs the daemon", len(supervisors) == 1 and len(children) == 1, running)

# A crash: the supervisor starts the daemon again.
subprocess.run(["taskkill", "/F", "/PID", str(children[0])], capture_output=True, timeout=30)
restarted = wait_for(lambda: [pid for pid, command in daemons().items()
                              if " --supervise " not in command and pid != children[0]], 15)
check("the supervisor restarts a daemon that crashed", restarted, daemons())
check("the restarted daemon answers", fyke("status").returncode == 0)

# A clean stop is the person's choice, and the supervisor goes with the daemon.
p = fyke("daemon", "stop")
check("daemon stop succeeds", p.returncode == 0, p.stdout + p.stderr)
check("a clean stop ends the supervisor too", wait_for(lambda: not daemons() or None, 10), daemons())
p = fyke("service", "install")
check("installing again starts it again", p.returncode == 0 and len(daemons()) == 2, daemons())

p = fyke("service", "status")
check("status reports installed", p.stdout.strip() == "installed", p.stdout + p.stderr)
p = fyke("service", "install")
check("installing twice is fine", p.returncode == 0, p.stdout + p.stderr)

# What the key holds is what the system runs at sign-in, so run it the same way.
fyke("daemon", "stop")
time.sleep(0.5)
command = text.split("REG_SZ", 1)[1].strip()
subprocess.Popen(command, creationflags=0x00000008 | 0x00000200, close_fds=True)
# The socket file outlives a daemon on Windows, so wait for the supervisor's child, not
# the file. A client started sooner would start a daemon of its own.
wait_for(lambda: [pid for pid, command in daemons().items() if " --supervise " not in command], 15)
p = fyke("status")
check("the stored command starts a working daemon", p.returncode == 0, p.stdout + p.stderr)
check("under its supervisor", any(" --supervise " in command for command in daemons().values()), daemons())

p = fyke("service", "uninstall")
check("uninstall succeeds", p.returncode == 0, p.stdout + p.stderr)
check("the value is removed", value() is None, value())
p = fyke("service", "status")
check("status reports not installed again", p.stdout.strip() == "not installed", p.stdout + p.stderr)
p = fyke("service", "uninstall")
check("uninstalling twice is fine", p.returncode == 0, p.stdout + p.stderr)

cleanup()
print(f"\n{passed} checks passed")

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
check("it runs this binary with the daemon arguments", FYKE.lower() in text.lower() and " daemon --log " in text, text)
check("it names the data folder", home.lower() in text.lower(), text)
check("the daemon is running now", os.path.exists(home + r"\fyked.sock") or fyke("status").returncode == 0)

p = fyke("service", "status")
check("status reports installed", p.stdout.strip() == "installed", p.stdout + p.stderr)
p = fyke("service", "install")
check("installing twice is fine", p.returncode == 0, p.stdout + p.stderr)

# What the key holds is what the system runs at sign-in, so run it the same way.
fyke("daemon", "stop")
time.sleep(0.5)
command = text.split("REG_SZ", 1)[1].strip()
subprocess.Popen(command, creationflags=0x00000008 | 0x00000200, close_fds=True)
deadline = time.time() + 10
while time.time() < deadline and not os.path.exists(home + r"\fyked.sock"):
    time.sleep(0.1)
p = fyke("status")
check("the stored command starts a working daemon", p.returncode == 0, p.stdout + p.stderr)

p = fyke("service", "uninstall")
check("uninstall succeeds", p.returncode == 0, p.stdout + p.stderr)
check("the value is removed", value() is None, value())
p = fyke("service", "status")
check("status reports not installed again", p.stdout.strip() == "not installed", p.stdout + p.stderr)
p = fyke("service", "uninstall")
check("uninstalling twice is fine", p.returncode == 0, p.stdout + p.stderr)

cleanup()
print(f"\n{passed} checks passed")

#!/usr/bin/env python3
"""Installs, upgrades and uninstalls Fyke with its Windows installer, as a person would.

    e2e_installer_windows.py <older setup.exe> <newer setup.exe>

Runs both installers silently for the current user, with FYKE_HOME pointing at a fresh
folder so that the service the installer registers serves this test's data and not a
real one. Checks the files, Start menu entry, PATH, sign-in entry and running daemon;
that an upgrade over a running daemon replaces it and keeps the tasks chosen before;
and that uninstalling removes everything but the data.

It changes the real per-user install of Fyke, its Run key and PATH, so it refuses to
run where Fyke is already installed unless CI is set.
"""
import os, shutil, subprocess, sys, tempfile, time, winreg  # noqa: E401

if os.name != "nt":
    print("this test runs on Windows only"); sys.exit(0)

OLD, NEW = (os.path.abspath(path) for path in sys.argv[1:3])
APP_ID = "{B4FB2AE1-5D43-423D-BC0B-6BC185FDB49C}_is1"
UNINSTALL = r"Software\Microsoft\Windows\CurrentVersion\Uninstall" + "\\" + APP_ID
RUN = r"Software\Microsoft\Windows\CurrentVersion\Run"
INSTALL = os.path.join(os.environ["LOCALAPPDATA"], "Programs", "Fyke")
START_MENU = os.path.join(os.environ["APPDATA"], r"Microsoft\Windows\Start Menu\Programs\Fyke.lnk")
FYKE = os.path.join(INSTALL, "fyke.exe")

root = tempfile.mkdtemp(prefix="fyke-i-")
home = os.path.join(root, "data")
env = dict(os.environ, FYKE_HOME=home)


def read(key, name):
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key) as opened:
            return winreg.QueryValueEx(opened, name)[0]
    except OSError:
        return None


def user_path():
    return [entry for entry in (read("Environment", "Path") or "").split(";") if entry]


def fyke(*args):
    return subprocess.run([FYKE, *args], env=env, capture_output=True, text=True, timeout=60)


def setup(installer, *tasks):
    log = os.path.join(root, os.path.basename(installer) + ".log")
    args = [installer, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", f"/LOG={log}"]
    if tasks:
        args.append("/TASKS=" + ",".join(tasks))
    p = subprocess.run(args, env=env, timeout=300)
    return p.returncode, log


def wait_for(predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.5)
    return False


def daemons():
    """The fyke processes serving this test's folder, as {pid: command line}. Asking the
    daemon itself would not do: a client starts one when none is running."""
    script = ("Get-CimInstance Win32_Process -Filter \"Name='fyke.exe'\" | "
              "ForEach-Object { \"$($_.ProcessId)`t$($_.CommandLine)\" }")
    p = subprocess.run(["powershell", "-NoProfile", "-Command", script], capture_output=True, text=True, timeout=60)
    found = {}
    for line in p.stdout.splitlines():
        pid, _, command = line.partition("\t")
        if home.lower() in command.lower():
            found[int(pid)] = command
    return found


def supervised():
    """The daemon's pid, when the installed supervisor runs one for this folder."""
    running = daemons()
    supervisors = [pid for pid, command in running.items() if "--supervise" in command]
    children = [pid for pid, command in running.items() if "--supervise" not in command]
    return children[0] if supervisors and children else None


if read(UNINSTALL, "DisplayVersion") is not None and not os.environ.get("CI"):
    print("Fyke is installed for this user; refusing to replace it outside CI"); sys.exit(2)

passed = 0


def check(name, ok, detail=""):
    global passed
    if not ok:
        print("FAIL", name, detail)
        cleanup(); sys.exit(1)
    passed += 1; print("ok  ", name)


def cleanup():
    uninstaller = os.path.join(INSTALL, "unins000.exe")
    if os.path.exists(uninstaller):
        subprocess.run([uninstaller, "/VERYSILENT", "/SUPPRESSMSGBOXES"], env=env, timeout=120)
        wait_for(lambda: read(UNINSTALL, "DisplayVersion") is None, 60)
    shutil.rmtree(root, ignore_errors=True)


def installed_version():
    return read(UNINSTALL, "DisplayVersion")


# A first install, with the tasks a person leaves checked.
code, log = setup(OLD, "startup", "path")
check("the older installer succeeds", code == 0, open(log, errors="replace").read()[-3000:])
old_version = installed_version()
check("it registers for Apps and features", old_version is not None)
for name in ("Fyke.App.exe", "fyke.exe", r"Fonts\Newsreader-Variable.ttf", r"Assets\Fyke.ico", "Fyke.App.pri"):
    check(f"it installs {name}", os.path.isfile(os.path.join(INSTALL, name)))
check("it adds Fyke to the Start menu", os.path.isfile(START_MENU))
check("it adds the install folder to PATH", any(entry.lower() == INSTALL.lower() for entry in user_path()), user_path())
command = read(RUN, "Fyke") or ""
check("it starts the daemon at sign-in, supervised", FYKE.lower() in command.lower() and "--supervise" in command, command)
check("it names this test's data folder", home.lower() in command.lower(), command)
check("the daemon is running under its supervisor", wait_for(lambda: supervised() is not None, 20), daemons())
before = supervised()
check("it answers", fyke("status").returncode == 0)
check("the data folder is outside the install", os.path.isfile(os.path.join(home, "fyke.db")))
with open(os.path.join(home, "kept.txt"), "w") as marker:
    marker.write("the person's own file")

# The installed app is open, and so is a copy run from somewhere else. A stand-in with no
# window does for that copy: the installer must not touch it, window or not.
app = subprocess.Popen([os.path.join(INSTALL, "Fyke.App.exe")], env=dict(env, FYKE_HEADLESS="1"))
elsewhere = os.path.join(root, "elsewhere")
os.makedirs(elsewhere)
shutil.copy(os.path.join(os.environ["SystemRoot"], "System32", "ping.exe"), os.path.join(elsewhere, "Fyke.App.exe"))
other = subprocess.Popen([os.path.join(elsewhere, "Fyke.App.exe"), "-n", "600", "127.0.0.1"],
                         stdout=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
check("the installed app is open", not wait_for(lambda: app.poll() is not None, 5), app.poll())

# An upgrade, over the running daemon, choosing nothing: the tasks chosen before stay.
code, log = setup(NEW)
check("the upgrade closes the installed app", wait_for(lambda: app.poll() is not None, 10))
check("and leaves a Fyke.App.exe run from elsewhere", other.poll() is None, other.poll())
other.kill()
check("the newer installer succeeds over a running daemon", code == 0, open(log, errors="replace").read()[-3000:])
check("the version is the newer one", installed_version() not in (None, old_version), installed_version())
check("there is still one entry in PATH", sum(entry.lower() == INSTALL.lower() for entry in user_path()) == 1, user_path())
check("the sign-in entry stays", "--supervise" in (read(RUN, "Fyke") or ""))
check("a new daemon runs after the upgrade", wait_for(lambda: supervised() not in (None, before), 20), daemons())
check("it answers", fyke("status").returncode == 0)
check("the data survives the upgrade", os.path.isfile(os.path.join(home, "kept.txt")))

# Uninstalling: everything goes but the data.
uninstaller = os.path.join(INSTALL, "unins000.exe")
check("there is an uninstaller", os.path.isfile(uninstaller))
subprocess.run([uninstaller, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"], env=env, timeout=300)
check("it leaves Apps and features", wait_for(lambda: installed_version() is None, 120))
check("it removes the program files", wait_for(lambda: not os.path.exists(FYKE), 30),
      os.listdir(INSTALL) if os.path.isdir(INSTALL) else "")
check("it removes the Start menu entry", not os.path.exists(START_MENU))
# The uninstaller finishes on its own after the entry in Apps goes, so wait for each step.
check("it removes the PATH entry",
      wait_for(lambda: all(entry.lower() != INSTALL.lower() for entry in user_path()), 30), user_path())
check("it removes the sign-in entry", wait_for(lambda: read(RUN, "Fyke") is None, 30), read(RUN, "Fyke"))
check("it stops the daemon and its supervisor", wait_for(lambda: not daemons(), 20), daemons())
check("it keeps the database", os.path.isfile(os.path.join(home, "fyke.db")))
check("it keeps the person's files", os.path.isfile(os.path.join(home, "kept.txt")))

shutil.rmtree(root, ignore_errors=True)
print(f"\n{passed} checks passed")

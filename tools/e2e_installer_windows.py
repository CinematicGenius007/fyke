#!/usr/bin/env python3
"""Installs, upgrades and uninstalls Fyke with its Windows installer, as a person would.

    e2e_installer_windows.py <older setup.exe> <newer setup.exe>

Runs both installers silently (/S) for the current user, with FYKE_HOME pointing at a
fresh folder so that the service the installer registers serves this test's data and not
a real one. Checks the files, Start menu entry, PATH, sign-in entry and running daemon;
that an upgrade over a running daemon closes only the app it installed, replaces the
daemon and keeps the choices made before; that the choices can be turned off; and that
uninstalling removes everything but the data.

tools/desktop_package.py builds the installers (desktop/src-tauri/windows/hooks.nsh holds
what Fyke adds to Tauri's). The test changes the real per-user install of Fyke, its Run
key and PATH, so it refuses to run where Fyke is already installed unless CI is set.
"""
import os, shutil, subprocess, sys, tempfile, time  # noqa: E401

if os.name != "nt":
    print("this test runs on Windows only"); sys.exit(0)
import winreg  # noqa: E402

OLD, NEW = (os.path.abspath(path) for path in sys.argv[1:3])
UNINSTALL = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Fyke"
RUN = r"Software\Microsoft\Windows\CurrentVersion\Run"
CHOICES = r"Software\Fyke\Installer"
DATA_DEFAULT = os.path.join(os.environ["LOCALAPPDATA"], "Fyke")
INSTALL = os.path.join(os.environ["LOCALAPPDATA"], "Programs", "Fyke")
START_MENU = os.path.join(os.environ["APPDATA"], r"Microsoft\Windows\Start Menu\Programs\Fyke.lnk")
APP = os.path.join(INSTALL, "Fyke.App.exe")
FYKE = os.path.join(INSTALL, "fyke.exe")
UNINSTALLER = os.path.join(INSTALL, "uninstall.exe")

root = tempfile.mkdtemp(prefix="fyke-i-")
home = os.path.join(root, "data")
env = dict(os.environ, FYKE_HOME=home)


def read(key, name):
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key) as opened:
            return winreg.QueryValueEx(opened, name)[0]
    except OSError:
        return None


def path_type():
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as opened:
            return winreg.QueryValueEx(opened, "Path")[1]
    except OSError:
        return None


def user_path():
    return [entry for entry in (read("Environment", "Path") or "").split(";") if entry]


def on_path():
    return sum(entry.rstrip("\\").lower() == INSTALL.lower() for entry in user_path())


def fyke(*args):
    return subprocess.run([FYKE, *args], env=env, capture_output=True, text=True, timeout=60)


def setup(installer, *options):
    return subprocess.run([installer, "/S", *options], env=env, timeout=600).returncode


def uninstall():
    """The uninstaller copies itself to a temporary folder and runs from there, so it
    returns at once; wait for the entry in Apps to go."""
    subprocess.run([UNINSTALLER, "/S"], env=env, timeout=300)
    return wait_for(lambda: read(UNINSTALL, "DisplayVersion") is None, 120)


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
    if os.path.exists(UNINSTALLER):
        uninstall()
    shutil.rmtree(root, ignore_errors=True)


def installed_version():
    return read(UNINSTALL, "DisplayVersion")


# A first install, with the choices a person leaves on.
code = setup(OLD, "/ADDTOPATH=1", "/BACKGROUND=1")
check("the older installer succeeds", code == 0, code)
old_version = installed_version()
check("it registers for Apps and features", old_version is not None)
location = (read(UNINSTALL, "InstallLocation") or "").strip('"')
check("it installs in Programs, not the data folder", location.lower() == INSTALL.lower(), location)
for name in ("Fyke.App.exe", "fyke.exe", "uninstall.exe"):
    check(f"it installs {name}", os.path.isfile(os.path.join(INSTALL, name)))
check("it puts nothing in the default data folder",
      not os.path.exists(os.path.join(DATA_DEFAULT, "Fyke.App.exe")) and not os.path.exists(os.path.join(DATA_DEFAULT, "uninstall.exe")))
check("it adds Fyke to the Start menu", os.path.isfile(START_MENU))
check("it adds the install folder to PATH once", on_path() == 1, user_path())
check("PATH stays an expandable string", path_type() == winreg.REG_EXPAND_SZ, path_type())
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
app = subprocess.Popen([APP], env=dict(env, FYKE_HEADLESS="1"))
elsewhere = os.path.join(root, "elsewhere")
os.makedirs(elsewhere)
shutil.copy(os.path.join(os.environ["SystemRoot"], "System32", "ping.exe"), os.path.join(elsewhere, "Fyke.App.exe"))
other = subprocess.Popen([os.path.join(elsewhere, "Fyke.App.exe"), "-n", "600", "127.0.0.1"],
                         stdout=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
check("the installed app is open", not wait_for(lambda: app.poll() is not None, 5), app.poll())

# An upgrade, over the running daemon, choosing nothing: the choices made before stay.
code = setup(NEW)
check("the upgrade closes the installed app", wait_for(lambda: app.poll() is not None, 10))
check("and leaves a Fyke.App.exe run from elsewhere", other.poll() is None, other.poll())
other.kill()
check("the newer installer succeeds over a running daemon", code == 0, code)
check("the version is the newer one", installed_version() not in (None, old_version), installed_version())
check("there is still one entry in PATH", on_path() == 1, user_path())
check("the sign-in entry stays", "--supervise" in (read(RUN, "Fyke") or ""))
check("a new daemon runs after the upgrade", wait_for(lambda: supervised() not in (None, before), 20), daemons())
check("it answers", fyke("status").returncode == 0)
check("the data survives the upgrade", os.path.isfile(os.path.join(home, "kept.txt")))

# The same version again, with both choices turned off.
code = setup(NEW, "/ADDTOPATH=0", "/BACKGROUND=0")
check("reinstalling with the choices off succeeds", code == 0, code)
check("it takes the folder off PATH", on_path() == 0, user_path())
check("it removes the sign-in entry", read(RUN, "Fyke") is None, read(RUN, "Fyke"))
check("it remembers the choices", read(CHOICES, "AddToPath") == 0 and read(CHOICES, "Background") == 0)
check("the data survives", os.path.isfile(os.path.join(home, "kept.txt")))
code = setup(NEW, "/ADDTOPATH=1", "/BACKGROUND=1")
check("and turning them on again works", code == 0 and on_path() == 1 and "--supervise" in (read(RUN, "Fyke") or ""))
check("the daemon runs again", wait_for(lambda: supervised() is not None, 20), daemons())

# Uninstalling: everything goes but the data.
check("there is an uninstaller", os.path.isfile(UNINSTALLER))
check("it leaves Apps and features", uninstall())
check("it removes the program files", wait_for(lambda: not os.path.exists(FYKE) and not os.path.exists(APP), 30),
      os.listdir(INSTALL) if os.path.isdir(INSTALL) else "")
check("it removes the Start menu entry", not os.path.exists(START_MENU))
check("it removes the PATH entry", wait_for(lambda: on_path() == 0, 30), user_path())
check("it removes the sign-in entry", wait_for(lambda: read(RUN, "Fyke") is None, 30), read(RUN, "Fyke"))
check("it forgets the choices", read(CHOICES, "AddToPath") is None)
check("it stops the daemon and its supervisor", wait_for(lambda: not daemons(), 20), daemons())
check("it keeps the database", os.path.isfile(os.path.join(home, "fyke.db")))
check("it keeps the person's files", os.path.isfile(os.path.join(home, "kept.txt")))

shutil.rmtree(root, ignore_errors=True)
print(f"\n{passed} checks passed")

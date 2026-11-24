#!/usr/bin/env python3
"""Installs, upgrades and removes Fyke's .deb, and runs its AppImage, as a person would.

    e2e_packages_linux.py <fyke_X_amd64.deb> <Fyke-X-x86_64.AppImage>

The .deb is installed with apt (sudo), over an older copy of itself: the same package
relabelled 0.0.1, so the upgrade path is dpkg's own. The installed app is launched in
test mode (FYKE_HEADLESS, FYKE_MEASURE) against a scratch FYKE_HOME, and must start the
installed daemon and draw. Removing the package must leave the data. The AppImage runs
from its own folder, with a scratch HOME, and must start the copy of the daemon it keeps
in ~/.local/share/fyke/bin (desktop/src-tauri/src/paths.rs, `appimage_daemon`).

It needs a display (CI runs it under xvfb-run) and changes the system's packages, so it
refuses to run where Fyke is installed unless CI is set.
"""
import os, pathlib, shutil, subprocess, sys, tempfile, time  # noqa: E401

if not sys.platform.startswith("linux"):
    print("this test runs on Linux only"); sys.exit(0)

DEB, APPIMAGE = (pathlib.Path(path).resolve() for path in sys.argv[1:3])
root = pathlib.Path(tempfile.mkdtemp(prefix="fyke-p-"))
passed = 0


def check(name, ok, detail=""):
    global passed
    if not ok:
        print("FAIL", name, detail)
        cleanup(); sys.exit(1)
    passed += 1; print("ok  ", name)


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=600, **kwargs)


def installed_version():
    p = run("dpkg-query", "-W", "-f=${Status} ${Version}", "fyke")
    return p.stdout.split()[-1] if p.returncode == 0 and "installed" in p.stdout and "not-installed" not in p.stdout else None


def wait_for(predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.25)
    return False


def daemons(home):
    """Command lines of the fyke daemons serving `home`."""
    found = []
    for proc in pathlib.Path("/proc").iterdir():
        try:
            parts = (proc / "cmdline").read_bytes().split(b"\0")
            environ = (proc / "environ").read_bytes().split(b"\0")
        except OSError:
            continue
        if parts and parts[0].endswith(b"fyke") and b"daemon" in parts and f"FYKE_HOME={home}".encode() in environ:
            found.append(" ".join(part.decode(errors="replace") for part in parts if part))
    return found


def launch(program, env):
    """Runs the app until it draws its first list; returns what it printed."""
    env = dict(env, FYKE_HEADLESS="1", FYKE_MEASURE="0")
    p = subprocess.run([str(program)], env=env, capture_output=True, text=True, timeout=120)
    return p.stdout.strip(), p.returncode, p.stderr[-2000:]


def cleanup():
    if installed_version() is not None:
        run("sudo", "apt-get", "remove", "-y", "fyke")
    shutil.rmtree(root, ignore_errors=True)


if installed_version() is not None and not os.environ.get("CI"):
    print("Fyke is installed on this system; refusing to replace it outside CI"); sys.exit(2)

# The package itself.
fields = run("dpkg-deb", "-f", DEB, "Package", "Version", "Depends").stdout
check("the package is called fyke", "Package: fyke" in fields, fields)
contents = run("dpkg-deb", "-c", DEB).stdout
held = {line.split()[-1].removeprefix("./") for line in contents.splitlines() if line.strip()}
for path in ("usr/bin/fyke-app", "usr/bin/fyke", "usr/share/applications/Fyke.desktop"):
    check(f"it holds /{path}", path in held, contents)

# An older copy, the same files relabelled 0.0.1.
older = root / "older"
run("dpkg-deb", "-R", DEB, older)
control = older / "DEBIAN" / "control"
control.write_text("".join("Version: 0.0.1\n" if line.startswith("Version:") else line
                           for line in control.read_text().splitlines(keepends=True)))
old_deb = root / "fyke_0.0.1_amd64.deb"
check("the older package builds", run("dpkg-deb", "--root-owner-group", "-b", older, old_deb).returncode == 0)

p = run("sudo", "apt-get", "install", "-y", "--allow-downgrades", old_deb)
check("the older package installs", p.returncode == 0 and installed_version() == "0.0.1", p.stdout[-2000:] + p.stderr[-2000:])
check("fyke is on PATH", shutil.which("fyke") == "/usr/bin/fyke", shutil.which("fyke"))
desktop = pathlib.Path("/usr/share/applications/Fyke.desktop").read_text()
check("the menu entry opens the app", "Exec=fyke-app" in desktop, desktop)

home = root / "data"
env = dict(os.environ, FYKE_HOME=str(home))
env.pop("FYKE_BIN", None)
out, code, err = launch("/usr/bin/fyke-app", env)
check("the installed app draws", out == "ready" and code == 0, (out, code, err))
check("it starts the installed daemon", wait_for(lambda: any(d.startswith("/usr/bin/fyke ") for d in daemons(home)), 10), daemons(home))
check("the daemon answers", run("/usr/bin/fyke", "status", env=env).returncode == 0)
(home / "kept.txt").write_text("the person's own file")

# An upgrade over the running daemon.
p = run("sudo", "apt-get", "install", "-y", DEB)
check("the newer package installs over it", p.returncode == 0 and installed_version() not in (None, "0.0.1"), p.stdout[-2000:] + p.stderr[-2000:])
check("the daemon still answers", run("/usr/bin/fyke", "status", env=env).returncode == 0)
out, code, err = launch("/usr/bin/fyke-app", env)
check("the upgraded app draws", out == "ready" and code == 0, (out, code, err))
check("the data survives the upgrade", (home / "kept.txt").is_file())
run("/usr/bin/fyke", "daemon", "stop", env=env)

# Removing it.
p = run("sudo", "apt-get", "remove", "-y", "fyke")
check("the package removes", p.returncode == 0 and installed_version() is None, p.stdout[-2000:] + p.stderr[-2000:])
check("the programs go", not os.path.exists("/usr/bin/fyke-app") and not os.path.exists("/usr/bin/fyke"))
check("the menu entry goes", not os.path.exists("/usr/share/applications/Fyke.desktop"))
check("the data stays", (home / "fyke.db").is_file() and (home / "kept.txt").is_file())

# The AppImage, run in place. Extracting it first needs no FUSE, which CI lacks.
person = root / "person"
person.mkdir()
image = root / APPIMAGE.name
shutil.copy2(APPIMAGE, image)
image.chmod(0o755)
appimage_home = root / "appimage-data"
env = {key: value for key, value in os.environ.items() if key not in ("FYKE_BIN", "XDG_DATA_HOME")}
env.update(HOME=str(person), FYKE_HOME=str(appimage_home), APPIMAGE_EXTRACT_AND_RUN="1")
out, code, err = launch(image, env)
check("the AppImage draws", out == "ready" and code == 0, (out, code, err))
kept = person / ".local/share/fyke/bin/fyke"
check("it keeps a copy of the daemon outside the image", kept.is_file() and os.access(kept, os.X_OK))
check("the daemon it starts is that copy", wait_for(lambda: any(d.startswith(f"{kept} ") for d in daemons(appimage_home)), 10),
      daemons(appimage_home))
check("the daemon outlives the app", run(kept, "status", env=env).returncode == 0)
run(kept, "daemon", "stop", env=env)

shutil.rmtree(root, ignore_errors=True)
print(f"\n{passed} checks passed")

#!/usr/bin/env python3
"""Builds the release archives for the version in VERSION.

    python3 tools/release.py                 builds dist/ for every target
    python3 tools/release.py --notes         prints the changelog section for this version
    python3 tools/release.py --check TAG     fails unless TAG is v<VERSION> and the changelog has its section
    python3 tools/release.py --targets x86_64-linux-musl,x86_64-windows-gnu
    python3 tools/release.py --desktop DIR   also lists the desktop packages in DIR

Each archive holds the `fyke` program, the licence, the changelog and the README, and is
named fyke-<version>-<target>. `SHA256SUMS` lists them. Zig cross-compiles every target
from one machine, so the same command runs anywhere Zig is installed.

The macOS app is not built here: it needs Xcode, so `tools/bundle_app.py` builds it on a
Mac. Nor are the Windows installer and Linux packages of the desktop app: CI builds and
tests them on each system (tools/desktop_package.py), and --desktop copies them into
dist/ beside the archives, so `SHA256SUMS` covers every file a release publishes.
"""
import argparse, hashlib, io, pathlib, re, shutil, subprocess, sys, tarfile, zipfile

root = pathlib.Path(__file__).resolve().parent.parent
dist = root / "dist"

# Linux builds are static (musl), so they run on any distribution.
TARGETS = [
    "x86_64-linux-musl",
    "aarch64-linux-musl",
    "x86_64-windows-gnu",
    "aarch64-macos",
    "x86_64-macos",
]


def version():
    text = (root / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", text):
        sys.exit(f"VERSION must be MAJOR.MINOR.PATCH, not {text!r}")
    return text


def changelog_section(number):
    """The text under the heading for `number`, which reads `## 0.1.0 - 2026-11-10`."""
    lines = (root / "CHANGELOG.md").read_text().splitlines()
    start = next((i for i, l in enumerate(lines) if re.match(rf"##\s+\[?{re.escape(number)}\]?(\s|$)", l)), None)
    if start is None:
        sys.exit(f"CHANGELOG.md has no section for {number}. Rename Unreleased to '## {number} - <date>' first.")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return "\n".join(lines[start + 1:end]).strip() + "\n"


def check(tag):
    number = version()
    if tag != f"v{number}":
        sys.exit(f"tag {tag} does not match VERSION {number}")
    changelog_section(number)
    print(f"{tag} matches VERSION and the changelog")


def build(target, number):
    out = dist / "build" / target
    shutil.rmtree(out, ignore_errors=True)
    subprocess.run(["zig", "build", "-Drelease", f"-Dtarget={target}", "--prefix", str(out)], cwd=root, check=True)
    windows = "windows" in target
    program = out / "bin" / ("fyke.exe" if windows else "fyke")
    if not program.exists():
        sys.exit(f"{program} was not built")
    name = f"fyke-{number}-{target}"
    extras = [(root / "LICENSE", "LICENSE"), (root / "CHANGELOG.md", "CHANGELOG.md"), (root / "README.md", "README.md")]
    if windows:
        archive = dist / f"{name}.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
            z.write(program, f"{name}/{program.name}")
            for path, arcname in extras: z.write(path, f"{name}/{arcname}")
    else:
        archive = dist / f"{name}.tar.gz"
        with tarfile.open(archive, "w:gz") as t:
            info = t.gettarinfo(str(program), f"{name}/fyke"); info.mode = 0o755
            with open(program, "rb") as f: t.addfile(info, f)
            for path, arcname in extras: t.add(path, f"{name}/{arcname}")
    return archive


DESKTOP_PACKAGES = ["Fyke-{v}-setup-x64.exe", "fyke_{v}_amd64.deb", "Fyke-{v}-x86_64.AppImage"]


def desktop_packages(folder, number):
    """The desktop app's packages for this version, copied into dist/. Each one must be
    there: a release without one of them is a mistake."""
    copied = []
    for pattern in DESKTOP_PACKAGES:
        name = pattern.format(v=number)
        found = list(folder.rglob(name))
        if len(found) != 1:
            sys.exit(f"{folder} holds {len(found)} copies of {name}, not one")
        shutil.copy2(found[0], dist / name)
        copied.append(dist / name)
    return copied


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--notes", action="store_true")
    parser.add_argument("--check", metavar="TAG")
    parser.add_argument("--targets", default=",".join(TARGETS))
    parser.add_argument("--desktop", metavar="DIR", type=pathlib.Path)
    args = parser.parse_args()
    number = version()
    if args.check: return check(args.check)
    if args.notes: return print(changelog_section(number), end="")

    changelog_section(number)  # A release without notes is a mistake, so fail before building.
    shutil.rmtree(dist, ignore_errors=True)
    dist.mkdir()
    archives = [build(t, number) for t in args.targets.split(",")]
    shutil.rmtree(dist / "build")
    if args.desktop:
        archives += desktop_packages(args.desktop, number)
    sums = "".join(f"{hashlib.sha256(a.read_bytes()).hexdigest()}  {a.name}\n" for a in archives)
    (dist / "SHA256SUMS").write_text(sums)
    (dist / "NOTES.md").write_text(changelog_section(number))
    print(sums, end="")


main()

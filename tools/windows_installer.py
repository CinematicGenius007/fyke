#!/usr/bin/env python3
"""Builds the per-user Windows installer, Fyke-<version>-setup-x64.exe.

    python tools/windows_installer.py --app <published Fyke.App> --daemon <fyke.exe> --out <dir>
        [--version 0.1.0] [--install-inno]

It compiles gui-windows/installer/Fyke.iss with Inno Setup 6. The version defaults to
VERSION. With --install-inno, Inno Setup is installed through Chocolatey when it is
missing, as on a CI runner. Prints the installer's path. Runs on Windows only.
"""
import argparse, os, pathlib, re, shutil, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
script = root / "gui-windows/installer/Fyke.iss"


def compiler():
    found = shutil.which("ISCC") or shutil.which("iscc")
    if found:
        return found
    for base in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles"), os.environ.get("LOCALAPPDATA")):
        for name in (r"Inno Setup 6\ISCC.exe", r"Programs\Inno Setup 6\ISCC.exe"):
            if base and pathlib.Path(base, name).exists():
                return str(pathlib.Path(base, name))
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--daemon", required=True, type=pathlib.Path)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    parser.add_argument("--version", default=(root / "VERSION").read_text().strip())
    parser.add_argument("--install-inno", action="store_true")
    args = parser.parse_args()

    if os.name != "nt":
        sys.exit("the installer is built on Windows")
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        sys.exit(f"the version must be MAJOR.MINOR.PATCH, not {args.version!r}")
    for path, what in ((args.app / "Fyke.App.exe", "the published app"), (args.daemon, "fyke.exe")):
        if not path.is_file():
            sys.exit(f"{what} is not at {path}")

    iscc = compiler()
    if iscc is None and args.install_inno:
        subprocess.run(["choco", "install", "innosetup", "-y", "--no-progress"], check=True)
        iscc = compiler()
    if iscc is None:
        sys.exit("Inno Setup 6 is not installed (https://jrsoftware.org/isinfo.php), or pass --install-inno")

    args.out.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        iscc, "/Q",
        f"/DAppVersion={args.version}",
        f"/DAppDir={args.app.resolve()}",
        f"/DDaemon={args.daemon.resolve()}",
        f"/DOutputDir={args.out.resolve()}",
        str(script),
    ], check=True)
    installer = args.out.resolve() / f"Fyke-{args.version}-setup-x64.exe"
    if not installer.is_file():
        sys.exit(f"Inno Setup did not write {installer}")
    print(installer)


if __name__ == "__main__":
    main()

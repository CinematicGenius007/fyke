#!/usr/bin/env python3
"""Builds the Windows installer or the Linux packages of the desktop app (desktop/).

    desktop_package.py [--fyke PATH] [--version X.Y.Z] [--out DIR]

On Windows it builds Fyke-<version>-setup-x64.exe, the per-user NSIS installer; on Linux
fyke_<version>_amd64.deb and Fyke-<version>-x86_64.AppImage. Each holds the app and the
`fyke` daemon beside it, which the app starts. The daemon is --fyke, or else built here
with `zig build -Drelease`. The version is VERSION's unless --version gives another (the
installer's upgrade test builds an older one).

Tauri builds the packages (`tauri build`), with desktop/src-tauri/tauri.bundle.conf.json
on top of the usual configuration: it names the daemon as an external binary, which
Tauri copies from desktop/src-tauri/binaries/fyke-<target triple>.
"""
import argparse, json, os, pathlib, re, shutil, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
desktop = root / "desktop"
tauri = desktop / "src-tauri"
windows = os.name == "nt"


def host_triple():
    out = subprocess.run(["rustc", "-vV"], capture_output=True, text=True, check=True).stdout
    return re.search(r"^host: (\S+)", out, re.M).group(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fyke", type=pathlib.Path)
    parser.add_argument("--version", default=(root / "VERSION").read_text().strip())
    parser.add_argument("--out", type=pathlib.Path, default=root / "dist")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        sys.exit(f"the version must be MAJOR.MINOR.PATCH, not {args.version!r}")
    if not (windows or sys.platform.startswith("linux")):
        sys.exit("the desktop packages are built on Windows or Linux")

    exe = ".exe" if windows else ""
    fyke = args.fyke
    if fyke is None:
        subprocess.run(["zig", "build", "-Drelease"], cwd=root, check=True)
        fyke = root / "zig-out" / "bin" / f"fyke{exe}"
    triple = host_triple()
    binaries = tauri / "binaries"
    binaries.mkdir(exist_ok=True)
    bundled = binaries / f"fyke-{triple}{exe}"
    shutil.copy2(fyke, bundled)
    if not windows:
        # Zig keeps DWARF in a Linux release build; the packages do not need it. (On
        # Windows it goes to a separate .pdb.)
        subprocess.run(["strip", "--strip-debug", str(bundled)], check=True)

    bundles = "nsis" if windows else "deb,appimage"
    bunx = shutil.which("bunx") or "bunx"
    subprocess.run([bunx, "tauri", "build", "--bundles", bundles,
                    "--config", str(tauri / "tauri.bundle.conf.json"),
                    "--config", json.dumps({"version": args.version})], cwd=desktop, check=True)

    built = tauri / "target" / "release" / "bundle"
    v = args.version
    if windows:
        wanted = {built / "nsis" / f"Fyke_{v}_x64-setup.exe": f"Fyke-{v}-setup-x64.exe"}
    else:
        wanted = {built / "deb" / f"Fyke_{v}_amd64.deb": f"fyke_{v}_amd64.deb",
                  built / "appimage" / f"Fyke_{v}_amd64.AppImage": f"Fyke-{v}-x86_64.AppImage"}
    args.out.mkdir(parents=True, exist_ok=True)
    for source, name in wanted.items():
        if not source.exists():
            sys.exit(f"{source} was not built")
        shutil.copy2(source, args.out / name)
        print(args.out / name)


if __name__ == "__main__":
    main()

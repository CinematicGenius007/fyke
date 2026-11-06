#!/usr/bin/env python3
"""Builds zig-out/rss_.app: the SwiftUI client, the rss binary and the fonts.

    zig build -Drelease && python3 tools/bundle_app.py
"""
import pathlib, plistlib, shutil, subprocess

root = pathlib.Path(__file__).resolve().parent.parent
subprocess.run(["swift", "build", "-c", "release", "--package-path", root / "gui"], check=True)
built = subprocess.run(["swift", "build", "-c", "release", "--package-path", root / "gui", "--show-bin-path"],
                       check=True, capture_output=True, text=True).stdout.strip()

app = root / "zig-out/rss_.app"
shutil.rmtree(app, ignore_errors=True)
macos = app / "Contents/MacOS"
macos.mkdir(parents=True)
shutil.copy(pathlib.Path(built) / "Reader", macos / "Reader")
shutil.copy(root / "zig-out/bin/rss", macos / "rss")
shutil.copytree(root / "gui/Fonts", app / "Contents/Resources/Fonts")
with open(app / "Contents/Info.plist", "wb") as out:
    plistlib.dump({
        "CFBundleName": "rss_",
        "CFBundleDisplayName": "rss_",
        "CFBundleIdentifier": "local.rss_.app",
        "CFBundleExecutable": "Reader",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1",
        "LSMinimumSystemVersion": "15.0",
        "NSHighResolutionCapable": True,
    }, out)
# Ad-hoc signed, so that macOS will run it on this machine.
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", app], check=True)
print(app)

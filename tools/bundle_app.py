#!/usr/bin/env python3
"""Builds zig-out/Fyke.app: the SwiftUI client, the fyke binary, the fonts and the icon.

    python3 tools/bundle_app.py             builds the app
    python3 tools/bundle_app.py --install   also copies it to /Applications

The app holds no data. Feeds and settings live in ~/.fyke, so replacing the app
keeps both.
"""
import pathlib, plistlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
identifier = "local.fyke.app"
version = (root / "VERSION").read_text().strip()


def run(*command):
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)


def make_icon(target):
    with tempfile.TemporaryDirectory() as temp:
        source = pathlib.Path(temp) / "icon.png"
        run("swift", root / "tools/gen_icon.swift", root / "gui/Fonts", source)
        iconset = pathlib.Path(temp) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, ""), (2, "@2x")):
                pixels = str(size * scale)
                run("sips", "-z", pixels, pixels, source, "--out", iconset / f"icon_{size}x{size}{suffix}.png")
        run("iconutil", "-c", "icns", iconset, "-o", target)


run("zig", "build", "-Drelease")
run("swift", "build", "-c", "release", "--package-path", root / "gui")
built = subprocess.run(["swift", "build", "-c", "release", "--package-path", root / "gui", "--show-bin-path"],
                       check=True, capture_output=True, text=True).stdout.strip()

app = root / "zig-out/Fyke.app"
shutil.rmtree(app, ignore_errors=True)
macos = app / "Contents/MacOS"
resources = app / "Contents/Resources"
macos.mkdir(parents=True)
resources.mkdir()
shutil.copy(pathlib.Path(built) / "Reader", macos / "Reader")
shutil.copy(root / "zig-out/bin/fyke", macos / "fyke")
shutil.copytree(root / "gui/Fonts", resources / "Fonts")
make_icon(resources / "AppIcon.icns")
with open(app / "Contents/Info.plist", "wb") as out:
    plistlib.dump({
        # The page viewer shows what a browser would, and some sites are plain http.
        "NSAppTransportSecurity": {"NSAllowsArbitraryLoadsInWebContent": True},
        "CFBundleName": "Fyke",
        "CFBundleDisplayName": "Fyke",
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": "Reader",
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "LSApplicationCategoryType": "public.app-category.news",
        "LSMinimumSystemVersion": "15.0",
        "NSHighResolutionCapable": True,
    }, out)
# Ad-hoc signed, so that macOS will run it on the machine that built it.
run("codesign", "--force", "--deep", "--sign", "-", app)

if "--install" in sys.argv:
    # An app installed under the earlier name would otherwise stay beside the new one.
    shutil.rmtree("/Applications/rss_.app", ignore_errors=True)
    target = pathlib.Path("/Applications/Fyke.app")
    shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(app, target, symlinks=True)
    print(target)
else:
    print(app)

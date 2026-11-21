#!/usr/bin/env python3
"""Writes the Windows app icon, gui-windows/src/Fyke.App/Assets/Fyke.ico, from the Mac one.

    python3 tools/gen_windows_icon.py

`tools/gen_icon.swift` draws the icon on a 1024 canvas with the margin macOS expects
around its tile. Windows icons fill their square, so this keeps the tile, scales it to
each size Windows asks for, and packs the sizes into one .ico of PNG images, which
Windows reads from Vista on. It runs on a Mac (Swift and `sips`); the .ico is checked in,
so building on Windows needs neither.
"""
import pathlib, struct, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
out = root / "gui-windows/src/Fyke.App/Assets/Fyke.ico"
# The tile is 824 of the canvas's 1024; a little more keeps its soft edge.
TILE = 840
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]


def pack(images):
    """An .ico holding each (size, PNG bytes), largest last as Windows lists them."""
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)
    entries, data = b"", b""
    for size, png in images:
        side = 0 if size >= 256 else size  # 0 means 256
        entries += struct.pack("<BBBBHHII", side, side, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    return header + entries + data


def main():
    if sys.platform != "darwin":
        sys.exit("gen_windows_icon.py needs a Mac: it draws with Swift and scales with sips")
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        subprocess.run(["swift", root / "tools/gen_icon.swift", root / "gui/Fonts", work / "canvas.png"], check=True)
        subprocess.run(["sips", "--cropToHeightWidth", str(TILE), str(TILE), work / "canvas.png",
                        "--out", work / "tile.png"], check=True, capture_output=True)
        images = []
        for size in SIZES:
            png = work / f"{size}.png"
            subprocess.run(["sips", "-z", str(size), str(size), work / "tile.png", "--out", png],
                           check=True, capture_output=True)
            images.append((size, png.read_bytes()))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(pack(images))
    print(f"wrote {out.relative_to(root)} ({out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()

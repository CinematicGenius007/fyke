#!/usr/bin/env python3
"""Renders docs/diagrams/*.mmd to a light and a dark SVG.

GitHub shows Markdown images on the reader's theme, and an SVG cannot read the
page's colors when it is loaded as an image. The renderer's fallback palette is
black on white, which vanishes on a dark page. This script renders once, then
writes two files with explicit palettes: name.svg for light pages and
name-dark.svg for dark ones. Markdown picks between them with <picture>.

    python3 tools/render_diagrams.py
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIAGRAMS = ROOT / "docs" / "diagrams"
RENDERER = "ondine@0.0.3"

# Defaults the renderer falls back to when the page sets no variables.
DEFAULT_BG = "var(--ondine-bg,#fff)"
DEFAULT_FG = "var(--ondine-fg,#000)"

LIGHT = {"bg": "#ffffff", "fg": "#1f2328"}
DARK = {"bg": "#0d1117", "fg": "#e6edf3"}


def themed(svg: str, palette: dict) -> str:
    if DEFAULT_BG not in svg or DEFAULT_FG not in svg:
        sys.exit("renderer output changed: palette defaults not found")
    svg = svg.replace(DEFAULT_BG, f"var(--ondine-bg,{palette['bg']})")
    return svg.replace(DEFAULT_FG, f"var(--ondine-fg,{palette['fg']})")


def main() -> None:
    sources = sorted(DIAGRAMS.glob("*.mmd"))
    subprocess.run(["npx", "-y", RENDERER, *map(str, sources)], check=True, cwd=ROOT)
    for source in sources:
        plain = source.with_suffix(".svg")
        raw = plain.read_text()
        plain.write_text(themed(raw, LIGHT))
        source.with_name(source.stem + "-dark.svg").write_text(themed(raw, DARK))
        print(f"{source.stem}: light and dark")


if __name__ == "__main__":
    main()

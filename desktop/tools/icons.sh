#!/bin/sh
# Draws the app icon with tools/gen_icon.swift (macOS only, as the Mac app's is) and
# makes the Windows and Linux sizes from it. The results are committed, so builds on
# other systems need no Swift.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swift "$here/../tools/gen_icon.swift" "$here/../gui/Fonts" "$work/icon.png"
cd "$here"
bunx tauri icon "$work/icon.png" -o "$work/out" >"$work/log" 2>&1 || { cat "$work/log"; exit 1; }
for file in 32x32.png 128x128.png 128x128@2x.png icon.ico icon.png; do
  cp "$work/out/$file" "src-tauri/icons/$file"
done

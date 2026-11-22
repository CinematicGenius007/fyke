// Compares the desktop app's pictures (zig-out/desktop-snapshots, from Playwright) with
// the Mac app's (zig-out/gui-snapshots, from tools/e2e_gui.py) and writes what differs
// to zig-out/parity: a picture per screen with differing pixels in red over a faded copy
// of the Mac's, and report.md and report.json with the share of equal pixels.
//
//     bun tools/parity.ts [names…] [--strict]
//
// The Mac saves its pictures in the color space of the display it ran on (an embedded
// ICC profile), so each is first converted to sRGB, which is what the desktop pictures
// are in. That conversion uses macOS's `sips`.
//
// A screen passes at 99.99 % of pixels equal. With --strict the tool exits 1 when any
// compared screen falls short; without it the report is for reading.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { PNG } from "pngjs";

export const TARGET = 99.99;

const repo = resolve(import.meta.dir, "../..");
const mac = join(repo, "zig-out/gui-snapshots");
const desktop = join(repo, "zig-out/desktop-snapshots");
const out = join(repo, "zig-out/parity");

const SRGB = "/System/Library/ColorSync/Profiles/sRGB Profile.icc";

/** Whether a PNG carries an ICC profile (an `iCCP` chunk). */
export function hasProfile(png: Buffer): boolean {
  for (let at = 8; at + 8 <= png.length; ) {
    const length = png.readUInt32BE(at);
    const type = png.toString("latin1", at + 4, at + 8);
    if (type === "iCCP") return true;
    if (type === "IDAT") return false;
    at += 12 + length;
  }
  return false;
}

/** The Mac's picture in sRGB, or a problem. */
function macPicture(name: string): PNG | string {
  const source = join(mac, `${name}.png`);
  const bytes = readFileSync(source);
  if (!hasProfile(bytes)) return PNG.sync.read(bytes);
  if (process.platform !== "darwin") return "the Mac picture has a display profile, which only macOS can convert";
  const converted = join(out, "mac", `${name}.png`);
  mkdirSync(join(out, "mac"), { recursive: true });
  const run = spawnSync("sips", ["-m", SRGB, source, "--out", converted], { encoding: "utf8" });
  if (run.status !== 0) return `sips could not convert it: ${run.stderr.trim()}`;
  return PNG.sync.read(readFileSync(converted));
}

export interface Result {
  name: string;
  equal: number;
  total: number;
  percent: number;
  pass: boolean;
  problem?: string;
}

/** Pixels are equal when every channel is within `tolerance` of the other's. */
export function compare(a: PNG, b: PNG, tolerance = 0): { equal: number; total: number; diff: PNG } {
  const width = Math.max(a.width, b.width);
  const height = Math.max(a.height, b.height);
  const diff = new PNG({ width, height });
  let equal = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const at = (y * width + x) * 4;
      const inA = x < a.width && y < a.height;
      const inB = x < b.width && y < b.height;
      const ia = (y * a.width + x) * 4;
      const ib = (y * b.width + x) * 4;
      let same = inA && inB;
      for (let c = 0; same && c < 4; c++) same = Math.abs(a.data[ia + c] - b.data[ib + c]) <= tolerance;
      if (same) {
        equal++;
        // The Mac's picture, faded, so the red stands out against where it belongs.
        for (let c = 0; c < 3; c++) diff.data[at + c] = 255 - Math.round((255 - a.data[ia + c]) * 0.25);
      } else {
        diff.data[at] = 230;
        diff.data[at + 1] = 30;
        diff.data[at + 2] = 30;
      }
      diff.data[at + 3] = 255;
    }
  }
  return { equal, total: width * height, diff };
}

function main() {
  const strict = process.argv.includes("--strict");
  const asked = process.argv.slice(2).filter((arg) => !arg.startsWith("--"));
  const names = asked.length
    ? asked
    : existsSync(desktop)
      ? readdirSync(desktop).filter((file) => file.endsWith(".png")).map((file) => basename(file, ".png")).sort()
      : [];
  if (!names.length) {
    console.error("No desktop pictures to compare. Run `bunx playwright test` in desktop/ first.");
    process.exit(1);
  }
  mkdirSync(out, { recursive: true });
  const results: Result[] = [];
  for (const name of names) {
    const ours = join(desktop, `${name}.png`);
    const theirs = join(mac, `${name}.png`);
    if (!existsSync(theirs) || !existsSync(ours)) {
      results.push({ name, equal: 0, total: 0, percent: 0, pass: false, problem: `missing ${existsSync(theirs) ? ours : theirs}` });
      continue;
    }
    const a = macPicture(name);
    if (typeof a === "string") {
      results.push({ name, equal: 0, total: 0, percent: 0, pass: false, problem: a });
      continue;
    }
    const b = PNG.sync.read(readFileSync(ours));
    const { equal, total, diff } = compare(a, b);
    writeFileSync(join(out, `${name}-diff.png`), PNG.sync.write(diff));
    const percent = (100 * equal) / total;
    const problem = a.width !== b.width || a.height !== b.height ? `sizes differ: Mac ${a.width}×${a.height}, desktop ${b.width}×${b.height}` : undefined;
    results.push({ name, equal, total, percent, pass: !problem && percent >= TARGET, problem });
  }
  const lines = [
    "# Desktop parity",
    "",
    `Pixels equal to the Mac app's picture. Target: ${TARGET} %. Differing pixels are red in each \`<name>-diff.png\`.`,
    "",
    "| Screen | Equal | Result |",
    "| --- | ---: | --- |",
    ...results.map((r) => `| ${r.name} | ${r.total ? r.percent.toFixed(2) + " %" : "–"} | ${r.pass ? "pass" : r.problem ?? "below target"} |`),
    "",
  ];
  writeFileSync(join(out, "report.md"), lines.join("\n"));
  writeFileSync(join(out, "report.json"), JSON.stringify({ target: TARGET, results }, null, 2) + "\n");
  for (const r of results) console.log(`${r.pass ? "pass" : "FAIL"} ${r.name.padEnd(24)} ${r.total ? r.percent.toFixed(3) + " %" : r.problem}`);
  console.log(`\nReport: ${join(out, "report.md")}`);
  if (strict && results.some((r) => !r.pass)) process.exit(1);
}

if (import.meta.main) main();

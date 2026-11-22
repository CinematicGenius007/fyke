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
  /** Equal without the anti-aliasing allowance. */
  exact?: number;
  total: number;
  percent: number;
  pass: boolean;
  problem?: string;
}

/** Channel difference below which two pixels count as the same color. */
export const TOLERANCE = 8;

function near(a: PNG, ia: number, b: PNG, ib: number, tolerance: number): boolean {
  for (let c = 0; c < 4; c++) if (Math.abs(a.data[ia + c] - b.data[ib + c]) > tolerance) return false;
  return true;
}

/** Whether pixel (x, y) of `a` matches some pixel within one pixel of (x, y) in `b`. */
function foundNear(a: PNG, b: PNG, x: number, y: number, tolerance: number): boolean {
  const ia = (y * a.width + x) * 4;
  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -1; dx <= 1; dx++) {
      const bx = x + dx;
      const by = y + dy;
      if (bx < 0 || by < 0 || bx >= b.width || by >= b.height) continue;
      if (near(a, ia, b, (by * b.width + bx) * 4, tolerance)) return true;
    }
  }
  return false;
}

/**
 * Pixels are equal when every channel is within `tolerance`. With `antialias`, a pixel
 * that differs still counts as equal when each picture has its color within one pixel
 * of the other's: the edge of a glyph or a curve rasterized a fraction of a pixel
 * apart. A shape that moved by a whole pixel or more, or a color that is not in the
 * other picture nearby, still differs. Those count in `exact` too, which is the share
 * without this allowance.
 */
export function compare(a: PNG, b: PNG, tolerance = TOLERANCE, antialias = true): { equal: number; exact: number; total: number; diff: PNG } {
  const width = Math.max(a.width, b.width);
  const height = Math.max(a.height, b.height);
  const diff = new PNG({ width, height });
  let equal = 0;
  let exact = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const at = (y * width + x) * 4;
      const inA = x < a.width && y < a.height;
      const inB = x < b.width && y < b.height;
      const ia = (y * a.width + x) * 4;
      const ib = (y * b.width + x) * 4;
      const same = inA && inB && near(a, ia, b, ib, tolerance);
      const edge = !same && antialias && inA && inB && foundNear(a, b, x, y, tolerance) && foundNear(b, a, x, y, tolerance);
      if (same) exact++;
      if (same || edge) {
        equal++;
        // The Mac's picture, faded, so the red stands out against where it belongs;
        // edges allowed as anti-aliasing in a faint orange.
        for (let c = 0; c < 3; c++) diff.data[at + c] = 255 - Math.round((255 - a.data[ia + c]) * 0.25);
        if (edge) {
          diff.data[at] = 250;
          diff.data[at + 1] = 200;
          diff.data[at + 2] = 150;
        }
      } else {
        diff.data[at] = 230;
        diff.data[at + 1] = 30;
        diff.data[at + 2] = 30;
      }
      diff.data[at + 3] = 255;
    }
  }
  return { equal, exact, total: width * height, diff };
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
    const { equal, exact, total, diff } = compare(a, b);
    writeFileSync(join(out, `${name}-diff.png`), PNG.sync.write(diff));
    const percent = (100 * equal) / total;
    const problem = a.width !== b.width || a.height !== b.height ? `sizes differ: Mac ${a.width}×${a.height}, desktop ${b.width}×${b.height}` : undefined;
    results.push({ name, equal, exact, total, percent, pass: !problem && percent >= TARGET, problem });
  }
  const lines = [
    "# Desktop parity",
    "",
    `Pixels equal to the Mac app's picture, within ${TOLERANCE} per channel, after the anti-aliasing allowance (an edge rasterized under a pixel apart). Target: ${TARGET} %. "Exact" is the share without the allowance. Differing pixels are red in each \`<name>-diff.png\`, allowed edges faint orange.`,
    "",
    "| Screen | Equal | Exact | Result |",
    "| --- | ---: | ---: | --- |",
    ...results.map((r) => `| ${r.name} | ${r.total ? r.percent.toFixed(3) + " %" : "–"} | ${r.total && r.exact !== undefined ? ((100 * r.exact) / r.total).toFixed(3) + " %" : "–"} | ${r.pass ? "pass" : r.problem ?? "below target"} |`),
    "",
  ];
  writeFileSync(join(out, "report.md"), lines.join("\n"));
  writeFileSync(join(out, "report.json"), JSON.stringify({ target: TARGET, results }, null, 2) + "\n");
  for (const r of results) console.log(`${r.pass ? "pass" : "FAIL"} ${r.name.padEnd(24)} ${r.total ? r.percent.toFixed(3) + " %" : r.problem}${r.total && r.exact !== undefined ? `  (exact ${((100 * r.exact) / r.total).toFixed(3)} %)` : ""}`);
  console.log(`\nReport: ${join(out, "report.md")}`);
  if (strict && results.some((r) => !r.pass)) process.exit(1);
}

if (import.meta.main) main();

// Colors must equal the Mac's to the 8-bit value, or the screens cannot compare.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { black, contrast, mix, parseHex, toHex } from "../../src/theme/color";
import { applying, builtIn, hexes, tokens } from "../../src/theme/palette";

describe("color", () => {
  test("mixing toward black matches SwiftUI's perceptual mix", () => {
    // Printed by SwiftUI on macOS: Color(hex).mix(with: .black, by: amount).
    const swift: [string, number, string][] = [
      ["#F1EEE6", 0.04, "#E4E1DA"],
      ["#F1EEE6", 0.07, "#DBD8D1"],
      ["#F1EEE6", 0.11, "#CECCC5"],
      ["#39FF88", 0.2, "#28BE63"],
      ["#39FF88", 0.93, "#000100"],
      ["#39FF88", 0.86, "#000902"],
      ["#39FF88", 0.8, "#011606"],
      ["#0A3CFF", 0.08, "#0835E4"],
      ["#0A3CFF", 0.15, "#062ECE"],
      ["#0A3CFF", 0.18, "#062CC4"],
      ["#8AA8FF", 0.08, "#7B96E4"],
      ["#8AA8FF", 0.18, "#6980C4"],
      ["#39FF88", 0.15, "#2CCE6C"],
    ];
    for (const [from, by, want] of swift) expect(toHex(mix(parseHex(from)!, black, by))).toBe(want);
  });

  test("hex reads six or eight digits and nothing else", () => {
    expect(parseHex("#00000033")).toEqual([0, 0, 0, 0x33]);
    expect(parseHex("0A3CFF")).toEqual([10, 60, 255, 255]);
    expect(parseHex("#12345")).toBeNull();
    expect(parseHex("#GGGGGG")).toBeNull();
    expect(toHex([0, 0, 0, 0x80])).toBe("#00000080");
  });

  test("contrast is WCAG's", () => {
    expect(contrast([0, 0, 0, 255], [255, 255, 255, 255])).toBeCloseTo(21, 5);
  });
});

describe("palette", () => {
  test("the light and dark tokens are gui/tokens.css", () => {
    const css = readFileSync(join(import.meta.dir, "../../../gui/tokens.css"), "utf8");
    const kebab = (name: string) => name.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
    for (const theme of ["light", "dark"] as const) {
      for (const [name, value] of Object.entries(tokens[theme])) {
        expect(css).toContain(`--color-${theme}-${kebab(name)}: ${value};`);
      }
    }
    for (const theme of ["newsprint", "terminal"] as const) {
      for (const [name, value] of Object.entries(tokens[theme])) expect(css).toContain(`--color-${theme}-${name}: ${value};`);
    }
    expect(css).toContain(`--font-reading: "${tokens.fonts.reading}";`);
    expect(css).toContain(`--radius-panel: ${tokens.radii.panel}px;`);
  });

  test("newsprint and terminal follow from three colors, as on the Mac", () => {
    expect(hexes(builtIn("newsprint"))).toMatchObject({ surface: "#E4E1DA", selected: "#DBD8D1", selectedStrong: "#CECCC5", muted: "#77736A", onAccent: "#F1EEE6" });
    expect(hexes(builtIn("terminal"))).toMatchObject({ ink: "#39FF88", inkSoft: "#28BE63", surface: "#000100", selected: "#000902", control: "#2A9D5C" });
    expect(builtIn("terminal").isDark).toBe(true);
    expect(builtIn("nonsense").id).toBe("light");
  });

  test("a custom theme overrides only what it names", () => {
    const dusk = applying(builtIn("dark"), { ground: "#1C1B29", ink_soft: "bad" }, "dusk");
    expect(dusk.id).toBe("dusk");
    expect(hexes(dusk).ground).toBe("#1C1B29");
    expect(hexes(dusk).inkSoft).toBe("#C8C8C8");
  });
});

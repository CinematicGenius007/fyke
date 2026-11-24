// SwiftUI sets a line of text at the font's own height and adds `lineSpacing` only
// between lines. CSS puts leading above and below every line. The stylesheets get the
// same result from each family's natural line height, measured here, plus the extra
// spacing as leading and a negative margin of half of it on each side.
//
//   --lh-ui, --lh-title, --lh-reading, --lh-code   natural line height ÷ font size
const kinds = ["ui", "title", "reading", "code"] as const;

export function measureLineHeights(root: HTMLElement = document.documentElement): void {
  const probe = document.createElement("span");
  probe.textContent = "Hg";
  Object.assign(probe.style, { position: "absolute", visibility: "hidden", lineHeight: "normal", fontSize: "100px", whiteSpace: "nowrap", top: "0", left: "-1000px" });
  document.body.append(probe);
  for (const kind of kinds) {
    probe.style.fontFamily = `var(--font-${kind})`;
    const ratio = probe.getBoundingClientRect().height / 100;
    if (ratio > 0) root.style.setProperty(`--lh-${kind}`, ratio.toFixed(4));
  }
  probe.remove();
}

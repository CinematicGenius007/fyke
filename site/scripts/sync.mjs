// Copies the rendered diagrams from docs/ so the site serves the files the
// documents already point at. The copy is not committed.
import { cpSync, mkdirSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
const from = new URL("../../docs/diagrams/", import.meta.url);
const to = new URL("../public/docs/diagrams/", import.meta.url);

rmSync(fileURLToPath(to), { recursive: true, force: true });
mkdirSync(fileURLToPath(to), { recursive: true });
cpSync(fileURLToPath(from), fileURLToPath(to), {
  recursive: true,
  filter: (src) => src.endsWith(".svg") || !src.includes("."),
});
console.log(`synced diagrams from ${from.pathname} (${here})`);

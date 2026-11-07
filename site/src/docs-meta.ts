// Title and summary of a design document, read from its Markdown. The summary is
// the first plain paragraph: what a search result or an answer engine quotes.
export function docTitle(body: string, fallback: string): string {
  return /^#\s+(.+)$/m.exec(body)?.[1].replace(/[`*_]/g, "") ?? fallback;
}

export function docSummary(body: string, fallback: string): string {
  const paragraphs = body
    .split(/\n{2,}/)
    .map((b) => b.trim())
    .filter((b) => b && !/^(#|<|!\[|```|\||-|\*|\d+\.|>)/.test(b));
  // A short "Status:" line says where a document stands, not what it is about, so the next paragraph is preferred.
  const first = /^Status:/i.test(paragraphs[0] ?? "") && paragraphs[0].length < 90 && paragraphs[1] ? paragraphs[1] : paragraphs[0];
  const plain = (first ?? "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[`*_]/g, "")
    .replace(/\s+/g, " ");
  if (!plain) return fallback;
  return plain.length > 155 ? `${plain.slice(0, plain.lastIndexOf(" ", 152))}…` : plain;
}

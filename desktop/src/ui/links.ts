// Feed content chooses link and image addresses, so only the web is reachable
// (gui/Sources/Reader/AppModel.swift `Links`).
export function isSafeLink(text: string | null | undefined): text is string {
  if (!text) return false;
  try {
    const url = new URL(text);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

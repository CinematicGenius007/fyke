// The line under a brief's or an answer's sources. Articles that matched but did not fit
// were never read, so that comes first; otherwise it counts what was read but not cited.
// Mirrors `SourcesNote` in gui/Sources/ReaderLogic/Logic.swift.
import { Plural } from "./Plural";

export const SourcesNote = {
  text(omitted: number, read: number, cited: number): string | null {
    if (omitted > 0) return `${Plural.count(omitted, "more article")} matched but did not fit, so the writer did not read them.`;
    return read > cited ? `${Plural.count(read - cited, "more", "more")} read but not cited` : null;
  },
};

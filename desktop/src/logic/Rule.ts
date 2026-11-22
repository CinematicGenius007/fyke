// A rule says which articles a view holds. It mirrors `Rule` in src/selector.zig, which
// validates it; this side only shows it and edits it. Fields use the daemon's spelling,
// so a rule goes over the wire as it is.
// Mirrors gui/Sources/ReaderLogic/Rule.swift. Edits return a new rule; none mutates.

export type RuleState = "any" | "unread" | "starred" | "later";

export interface Rule {
  feeds?: number[] | null;
  folders?: number[] | null;
  state?: RuleState | null;
  words?: string | null;
  any_words?: boolean | null;
  host?: string | null;
  subdomains?: boolean | null;
  path_prefix?: string | null;
  exclude_path_prefix?: string[] | null;
  within_days?: number | null;
}

/** One part of a rule, as the sentence shows it and as one tap changes it. */
export type Clause = "state" | "scope" | "words" | "host" | "path" | "exclude" | "within";
export const clauses: readonly Clause[] = ["state", "scope", "words", "host", "path", "exclude", "within"];

const blank = (text: string) => text.trim().length === 0;
const tokens = (text: string) => text.split(/\s+/u).filter(Boolean);

/** Drops unset values, so equal rules have equal JSON. */
function compact(rule: Rule): Rule {
  const out: Rule = {};
  for (const [key, value] of Object.entries(rule) as [keyof Rule, unknown][]) {
    if (value !== null && value !== undefined) (out as Record<string, unknown>)[key] = value;
  }
  return out;
}

/**
 * The daemon writes every field back, with empty lists and defaults. Two rules that
 * select the same articles compare equal after this.
 */
function normalized(input: Rule): Rule {
  const rule: Rule = { ...input };
  if (rule.feeds?.length === 0) rule.feeds = null;
  if (rule.folders?.length === 0) rule.folders = null;
  if (rule.state === "any") rule.state = null;
  if (rule.words != null && blank(rule.words)) rule.words = null;
  if (rule.words == null || rule.any_words === false) rule.any_words = null;
  if (rule.host != null && blank(rule.host)) rule.host = null;
  if (rule.host == null || rule.subdomains === false) rule.subdomains = null;
  if (rule.path_prefix != null && blank(rule.path_prefix)) rule.path_prefix = null;
  if (rule.exclude_path_prefix?.length === 0) rule.exclude_path_prefix = null;
  return compact(rule);
}

/** The rule a search becomes when it is kept. Search matches every word, so the view does too. */
function fromSearch(query: string, unreadOnly: boolean): Rule {
  const words = tokens(query).join(" ");
  return normalized({ state: unreadOnly ? "unread" : null, words: words || null });
}

/** A path always starts with a slash, which people often leave out. */
function path(text: string): string | null {
  const trimmed = text.trim();
  if (!trimmed) return null;
  return trimmed.startsWith("/") ? trimmed : "/" + trimmed;
}

function setState(rule: Rule, state: RuleState): Rule {
  return normalized({ ...rule, state });
}

function setScope(rule: Rule, feeds: number[], folders: number[]): Rule {
  return normalized({ ...rule, feeds, folders });
}

/** Words are tokens, never syntax: runs of space collapse, and nothing is quoted. */
function setWords(rule: Rule, text: string, any: boolean): Rule {
  const words = tokens(text).join(" ");
  return normalized({ ...rule, words: words ? Array.from(words).slice(0, 200).join("") : null, any_words: any });
}

function setHost(rule: Rule, text: string, subdomains: boolean): Rule {
  let host = text.trim().toLowerCase();
  // People paste addresses. Only the host is kept.
  try {
    const found = new URL(host).hostname;
    if (found) host = found;
  } catch {
    // Not an address: the text is the host.
  }
  host = host.replace(/^[./]+|[./]+$/gu, "");
  return normalized({ ...rule, host: host || null, subdomains });
}

function setPath(rule: Rule, text: string): Rule {
  return normalized({ ...rule, path_prefix: path(text) });
}

function addExclude(rule: Rule, text: string): Rule {
  const added = path(text);
  if (!added) return rule;
  const list = [...(rule.exclude_path_prefix ?? [])];
  if (!list.includes(added)) list.push(added);
  return normalized({ ...rule, exclude_path_prefix: list });
}

function removeExclude(rule: Rule, removed: string): Rule {
  if (!rule.exclude_path_prefix) return normalized(rule);
  return normalized({ ...rule, exclude_path_prefix: rule.exclude_path_prefix.filter((p) => p !== removed) });
}

function setWithin(rule: Rule, days: number | null): Rule {
  return compact({ ...rule, within_days: days == null ? null : Math.min(Math.max(days, 1), 3650) });
}

function clear(rule: Rule, clause: Clause): Rule {
  const next: Rule = { ...rule };
  switch (clause) {
    case "state":
      next.state = null;
      break;
    case "scope":
      next.feeds = null;
      next.folders = null;
      break;
    case "words":
      next.words = null;
      next.any_words = null;
      break;
    case "host":
      next.host = null;
      next.subdomains = null;
      break;
    case "path":
      next.path_prefix = null;
      break;
    case "exclude":
      next.exclude_path_prefix = null;
      break;
    case "within":
      next.within_days = null;
      break;
  }
  return normalized(next);
}

/** Clauses a person can still add, in sentence order. */
function missing(input: Rule): Clause[] {
  const rule = normalized(input);
  const out: Clause[] = [];
  if (rule.words == null) out.push("words");
  if (rule.host == null) out.push("host");
  if (rule.path_prefix == null) out.push("path");
  out.push("exclude");
  if (rule.within_days == null) out.push("within");
  return out;
}

/** Whether two rules select the same articles. */
function same(a: Rule, b: Rule): boolean {
  const order = (r: Rule) => JSON.stringify(Object.fromEntries(Object.entries(normalized(r)).sort(([x], [y]) => x.localeCompare(y))));
  return order(a) === order(b);
}

export const Rule = {
  normalized,
  fromSearch,
  path,
  setState,
  setScope,
  setWords,
  setHost,
  setPath,
  addExclude,
  removeExclude,
  setWithin,
  clear,
  missing,
  same,
};

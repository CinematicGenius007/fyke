// Wire types, as gui/Sources/Reader/Models.swift reads them. They mirror the Result
// structs in src/ops.zig and src/store.zig, in the daemon's snake_case spelling.
//
// The reader-feature records (views, recipes, briefs, routines, jobs) carry optional
// fields that vary with what a record holds, so they are read field by field through
// `J`, and a missing or extra field never fails a whole screen.
import type { Rule } from "../logic/Rule";
import { Rule as Rules } from "../logic/Rule";
import type { Schedule } from "../logic/Schedule";

export interface Items<T> {
  items: T[];
}

export interface Feed {
  id: number;
  url: string;
  site_url?: string | null;
  title?: string | null;
  status: string;
  error_count: number;
  last_error?: string | null;
  unread: number;
  entries: number;
  folder_id?: number | null;
  starred: number;
}

/** The title, else the address's host, else the address. */
export function feedName(feed: Pick<Feed, "title" | "url">): string {
  if (feed.title) return feed.title;
  try {
    return new URL(feed.url).hostname || feed.url;
  } catch {
    return feed.url;
  }
}

export interface Folder {
  id: number;
  parent_id?: number | null;
  name: string;
}

export interface EntrySummary {
  id: number;
  feed_id: number;
  feed_title?: string | null;
  title?: string | null;
  url?: string | null;
  sort_at: number;
  read: boolean;
  starred: boolean;
  later?: boolean | null;
  snippet?: string | null;
  summary?: string | null;
}

/** One line of preview. Stored text keeps the article's line breaks. */
export function preview(entry: Pick<EntrySummary, "snippet" | "summary">): string | null {
  const text = (entry.snippet ?? entry.summary)?.split(/\s+/u).filter(Boolean).join(" ");
  return text ? text : null;
}

export const entryDate = (entry: { sort_at: number }) => new Date(entry.sort_at);

export interface EntryPage {
  items: EntrySummary[];
  next_cursor?: string | null;
}

export interface Entry {
  id: number;
  feed_id: number;
  feed_title?: string | null;
  title?: string | null;
  url?: string | null;
  author?: string | null;
  published_at?: number | null;
  first_seen_at: number;
  read: boolean;
  starred: boolean;
  /** Where readers discuss the entry. Missing from daemons older than the field. */
  discussion_url?: string | null;
  /** The content model as JSON text (src/blocks.zig). */
  body: string;
}

export interface Stats {
  /** Missing from daemons older than the field. */
  api_version?: number | null;
  feeds: number;
  unread: number;
  last_event_seq: number;
}

export interface Candidate {
  url: string;
  title?: string | null;
  site_url?: string | null;
  format: string;
  latest: string[];
}

export interface AddResult {
  id: number;
  status: string;
  message?: string | null;
}

export interface ArticleUse {
  entries: number;
  feeds: number;
  text_bytes: number;
  search_bytes: number;
  other_bytes: number;
  removable: number;
  removable_bytes: number;
}

export interface StorageUse {
  articles: ArticleUse;
  database_bytes: number;
  raw_bytes: number;
  raw_files: number;
  log_bytes: number;
  settings_bytes: number;
}

export interface FreeResult {
  trimmed: number;
  copies_removed: number;
}

/**
 * One node of the content model (src/blocks.zig). Feed HTML never reaches the app: an
 * unknown kind renders as nothing.
 */
export interface Block {
  t: string;
  v?: string | null;
  lang?: string | null;
  src?: string | null;
  alt?: string | null;
  href?: string | null;
  level?: number | null;
  ordered?: boolean | null;
  items?: Block[][] | null;
  rows?: Block[][][] | null;
  c?: Block[] | null;
}

// MARK: Reading JSON field by field

/** Any JSON value, read leniently, as `JSON` in Models.swift. */
export class J {
  constructor(readonly value: unknown) {}

  static snake(key: string): string {
    return key.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
  }

  /** The first of `keys` present and not null, in either spelling. */
  get(...keys: string[]): J | undefined {
    const map = this.value;
    if (!map || typeof map !== "object" || Array.isArray(map)) return undefined;
    for (const key of keys) {
      const found = (map as Record<string, unknown>)[key] ?? (map as Record<string, unknown>)[J.snake(key)];
      if (found !== undefined && found !== null) return new J(found);
    }
    return undefined;
  }

  get string(): string | undefined {
    if (typeof this.value === "string") return this.value;
    if (typeof this.value === "number") return Number.isInteger(this.value) ? String(this.value) : String(this.value);
    return undefined;
  }

  get int(): number | undefined {
    if (typeof this.value === "number") return Math.trunc(this.value);
    if (typeof this.value === "string" && /^-?\d+$/.test(this.value.trim())) return Number(this.value.trim());
    return undefined;
  }

  get double(): number | undefined {
    return typeof this.value === "number" ? this.value : undefined;
  }

  get bool(): boolean | undefined {
    if (typeof this.value === "boolean") return this.value;
    if (typeof this.value === "number") return this.value !== 0;
    return undefined;
  }

  get array(): J[] {
    return Array.isArray(this.value) ? this.value.map((v) => new J(v)) : [];
  }

  /** Some fields hold JSON written as text, such as a rule stored as `rule_json`. */
  get parsed(): J | undefined {
    if (typeof this.value === "string") {
      try {
        return new J(JSON.parse(this.value));
      } catch {
        return undefined;
      }
    }
    return this;
  }
}

/** The daemon stores times as Unix milliseconds; seconds are accepted too. Zero marks a
 * record that came with the database, such as a built-in recipe. */
export function daemonDate(value: J | undefined): Date | null {
  const number = value?.double;
  if (number === undefined || !(number > 0)) return null;
  return new Date(number > 10_000_000_000 ? number : number * 1000);
}

function rule(value: J | undefined): Rule | null {
  const v = value?.parsed?.value;
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Rule) : null;
}

// MARK: Reader features

export interface SavedView {
  id: number;
  name: string;
  rule: Rule;
  sentence: string | null;
  unread: number;
  total: number;
  revision: number;
  position: number;
}

export function savedView(j: J): SavedView | null {
  const id = j.get("id")?.int;
  if (id === undefined) return null;
  return {
    id,
    name: j.get("name")?.string ?? "View",
    rule: Rules.normalized(rule(j.get("rule")) ?? rule(j.get("ruleJson")) ?? {}),
    sentence: j.get("sentence")?.string ?? null,
    unread: j.get("unread")?.int ?? j.get("unreadCount")?.int ?? 0,
    total: j.get("total")?.int ?? j.get("count")?.int ?? 0,
    revision: j.get("revision")?.int ?? 1,
    position: j.get("position")?.int ?? 0,
  };
}

export interface Recipe {
  id: number;
  name: string;
  text: string;
  revision: number;
  builtIn: boolean;
  updatedAt: Date | null;
  usedBy: number | null;
}

export function recipe(j: J): Recipe | null {
  const id = j.get("id")?.int;
  if (id === undefined) return null;
  return {
    id,
    name: j.get("name")?.string ?? "Recipe",
    text: j.get("text")?.string ?? "",
    revision: j.get("revision")?.int ?? 1,
    builtIn: j.get("builtin", "builtIn", "hasBuiltin")?.bool ?? j.get("builtinText") !== undefined,
    updatedAt: daemonDate(j.get("updatedAt", "createdAt")),
    usedBy: j.get("usedBy", "routines")?.int ?? null,
  };
}

export interface RecipeRevision {
  revision: number;
  text: string | null;
  note: string;
  createdAt: Date | null;
}

export function recipeRevision(j: J): RecipeRevision | null {
  const revision = j.get("revision")?.int;
  if (revision === undefined) return null;
  return { revision, text: j.get("text")?.string ?? null, note: j.get("note")?.string ?? "", createdAt: daemonDate(j.get("createdAt")) };
}

export interface Writer {
  id: string;
  name: string;
  /** Installed and signed in: a brief can be written. */
  found: boolean;
  /** On this computer, whether or not it is signed in. */
  installed: boolean;
  path: string | null;
  version: string | null;
  selected: boolean;
  problem: string | null;
  /** The Claude Code profile folder in use; null means Claude Code's default. */
  profile: string | null;
}

export function writer(j: J): Writer | null {
  const id = j.get("id", "writer", "name")?.string;
  if (id === undefined) return null;
  const found = j.get("found", "available")?.bool ?? false;
  return {
    id,
    name: j.get("label", "displayName", "title")?.string ?? (id === "claude" ? "Claude Code" : id === "codex" ? "Codex" : id),
    found,
    installed: j.get("installed")?.bool ?? found,
    profile: j.get("profile")?.string ?? null,
    path: j.get("path")?.string ?? null,
    version: j.get("version")?.string ?? null,
    selected: j.get("selected", "default")?.bool ?? false,
    problem: j.get("error", "problem", "lastError")?.string ?? null,
  };
}

/** One numbered source of a brief or answer. */
export interface Citation {
  number: number;
  entryId: number;
  title: string;
  feedTitle: string | null;
  snippet: string | null;
  url: string | null;
  date: Date | null;
  read: boolean;
}

export function citation(j: J, fallback: number): Citation | null {
  const entryId = j.get("entryId", "id")?.int;
  if (entryId === undefined) return null;
  return {
    number: j.get("n", "number", "index")?.int ?? fallback,
    entryId,
    title: j.get("title")?.string ?? "Untitled",
    feedTitle: j.get("feedTitle", "feed")?.string ?? null,
    snippet: j.get("snippet", "quote", "summary")?.string ?? null,
    url: j.get("url")?.string ?? null,
    date: daemonDate(j.get("sortAt", "publishedAt", "date")),
    read: j.get("read")?.bool ?? false,
  };
}

/** One claim of a written section and the sources it cites. */
export interface Claim {
  text: string;
  sources: number[];
}

export interface Section {
  heading: string | null;
  claims: Claim[];
}

/** A brief or an answer: generated text, labeled with who wrote it and from what. */
export interface Artifact {
  id: number;
  kind: string;
  title: string;
  question: string | null;
  createdAt: Date | null;
  viewId: number | null;
  viewName: string | null;
  rule: Rule | null;
  writer: string | null;
  recipeId: number | null;
  recipeName: string | null;
  recipeRevision: number | null;
  inputCount: number;
  omittedCount: number;
  durationSeconds: number | null;
  sections: Section[];
  citations: Citation[];
}

export function artifact(j: J): Artifact | null {
  const id = j.get("id")?.int;
  if (id === undefined) return null;
  const sources = j.get("citations", "sources", "citationsJson")?.parsed?.array ?? [];
  const citations = sources.map((s, i) => citation(s, i + 1)).filter((c): c is Citation => c !== null);
  const durationMs = j.get("durationMs")?.int;
  return {
    id,
    kind: j.get("kind")?.string ?? "digest",
    title: j.get("title")?.string ?? "Brief",
    question: j.get("question")?.string ?? null,
    createdAt: daemonDate(j.get("createdAt")),
    viewId: j.get("viewId")?.int ?? null,
    viewName: j.get("viewName")?.string ?? null,
    rule: rule(j.get("rule", "ruleJson")),
    writer: j.get("writer", "producer")?.string ?? null,
    recipeId: j.get("recipeId")?.int ?? null,
    recipeName: j.get("recipeName")?.string ?? null,
    recipeRevision: j.get("recipeRevision")?.int ?? null,
    inputCount: j.get("inputCount")?.int ?? 0,
    omittedCount: j.get("omittedCount")?.int ?? 0,
    durationSeconds: durationMs !== undefined ? Math.trunc(durationMs / 1000) : (j.get("durationSeconds")?.int ?? null),
    sections: sections(j, citations),
    citations,
  };
}

/** Writers return sections of claims. A record may carry them as they came, or as
 * blocks where each claim is a paragraph with citation nodes. */
function sections(j: J, citations: Citation[]): Section[] {
  const raw = j.get("sections")?.parsed?.array ?? [];
  if (raw.length) {
    return raw.map((section) => ({
      heading: section.get("heading")?.string ?? null,
      claims: (section.get("claims")?.array ?? []).map((c) => ({
        text: c.get("text")?.string ?? "",
        sources: (c.get("sources")?.array ?? []).map((s) => s.int).filter((n): n is number => n !== undefined),
      })),
    }));
  }
  const blocks = j.get("blocks", "body", "bodyBlocksJson")?.parsed?.array ?? [];
  const out: Section[] = [];
  let heading: string | null = null;
  let claims: Claim[] = [];
  const flush = () => {
    if (heading !== null || claims.length) out.push({ heading, claims });
    heading = null;
    claims = [];
  };
  // A source given by entry id becomes its number in the list.
  const numberOf = new Map<number, number>();
  for (const c of citations) if (!numberOf.has(c.entryId)) numberOf.set(c.entryId, c.number);
  const claim = (nodes: J[]): Claim => {
    let text = "";
    let sources: number[] = [];
    for (const node of nodes) {
      const kind = node.get("t")?.string ?? "";
      const href = node.get("href")?.string;
      const linked = kind === "link" && href?.startsWith("fyke://entry/") ? Number(href.slice(13)) : NaN;
      if (Number.isInteger(linked)) {
        sources.push(numberOf.get(linked) ?? linked);
      } else if (kind === "cite" || kind === "citation") {
        const n = node.get("n")?.int;
        const entry = node.get("entryId", "entry")?.int;
        const v = node.get("v")?.string;
        if (n !== undefined) sources.push(n);
        else if (entry !== undefined && numberOf.has(entry)) sources.push(numberOf.get(entry)!);
        else if (v !== undefined && /^-?\d+$/.test(v)) sources.push(Number(v));
        for (const id of node.get("sources")?.array ?? []) {
          const value = id.int;
          if (value !== undefined) sources.push(numberOf.get(value) ?? value);
        }
      } else if (node.get("v")?.string !== undefined) {
        text += node.get("v")!.string;
      } else if (node.get("c")) {
        const inner = claim(node.get("c")!.array);
        text += inner.text;
        sources = sources.concat(inner.sources);
      }
    }
    return { text: text.replace(/^[ \t]+|[ \t]+$/g, ""), sources };
  };
  for (const block of blocks) {
    switch (block.get("t")?.string) {
      case "h":
      case "h2":
      case "h3":
      case "heading":
        flush();
        heading = block.get("v")?.string ?? claim(block.get("c")?.array ?? []).text;
        break;
      case "claim":
        claims.push({
          text: block.get("v", "text")?.string ?? "",
          sources: (block.get("sources")?.array ?? []).map((s) => s.int).filter((n): n is number => n !== undefined).map((n) => numberOf.get(n) ?? n),
        });
        break;
      default:
        claims.push(claim(block.get("c")?.array ?? [block]));
    }
  }
  flush();
  return out;
}

/** Background work, as the Activity popover lists it. */
export type JobState = "queued" | "running" | "done" | "failed" | "cancelled";

export interface Job {
  id: number;
  kind: string;
  state: JobState;
  title: string;
  error: string | null;
  progress: number | null;
  total: number | null;
  createdAt: Date | null;
  finishedAt: Date | null;
  artifactId: number | null;
  writer: string | null;
  routineId: number | null;
}

const jobStates: JobState[] = ["queued", "running", "done", "failed", "cancelled"];

export function jobTitle(kind: string): string {
  switch (kind) {
    case "brief":
    case "digest":
    case "synthesize":
      return "Writing a brief";
    case "try":
    case "brief_try":
      return "Trying a recipe";
    case "answer":
    case "ask":
      return "Answering a question";
    case "routine":
      return "Running a routine";
    case "refresh":
      return "Refreshing feeds";
    default:
      return kind.slice(0, 1).toUpperCase() + kind.slice(1);
  }
}

export function job(j: J): Job | null {
  const id = j.get("id")?.int;
  if (id === undefined) return null;
  const input = j.get("input")?.parsed;
  // A trial of a recipe is a brief that is not kept.
  const stage = j.get("kind", "stage")?.string ?? "job";
  const kind = input?.get("preview")?.bool === true ? "try" : stage;
  const state = j.get("status", "state")?.string as JobState | undefined;
  return {
    id,
    kind,
    routineId: input?.get("routineId")?.int ?? null,
    state: state && jobStates.includes(state) ? state : "queued",
    error: j.get("error")?.string ?? null,
    progress: j.get("progress", "done")?.int ?? null,
    total: j.get("total")?.int ?? null,
    createdAt: daemonDate(j.get("createdAt", "startedAt")),
    finishedAt: daemonDate(j.get("finishedAt")),
    artifactId: j.get("artifactId", "resultId")?.int ?? null,
    writer: j.get("writer")?.string ?? input?.get("writer")?.string ?? null,
    title: j.get("title", "label", "description")?.string ?? jobTitle(kind),
  };
}

export const jobIsActive = (job: Job) => job.state === "queued" || job.state === "running";
export const jobIsWriting = (job: Job) => ["brief", "digest", "synthesize", "try", "brief_try", "answer", "ask"].includes(job.kind);

/** What a routine does after it finds its matches. */
export type RoutineActionKind = "brief" | "notify" | "mark_read" | "star" | "tag";
export const routineActionKinds: RoutineActionKind[] = ["brief", "notify", "mark_read", "star", "tag"];

export interface RoutineAction {
  kind: RoutineActionKind;
  recipe_id?: number;
  tag?: string;
}

export function routineAction(j: J): RoutineAction | null {
  const raw = j.get("kind", "type", "action")?.string as RoutineActionKind | undefined;
  if (!raw || !routineActionKinds.includes(raw)) return null;
  const out: RoutineAction = { kind: raw };
  const recipeId = j.get("recipeId")?.int;
  const tag = j.get("tag")?.string;
  if (recipeId !== undefined) out.recipe_id = recipeId;
  if (tag !== undefined) out.tag = tag;
  return out;
}

export interface Routine {
  id: number | null;
  name: string;
  viewId: number | null;
  schedule: Schedule;
  actions: RoutineAction[];
  enabled: boolean;
  revision: number | null;
  nextRunAt: Date | null;
  lastRunAt: Date | null;
  lastMatches: number | null;
}

export function newRoutine(name: string, viewId: number | null): Routine {
  return {
    id: null,
    name,
    viewId,
    schedule: { kind: "weekdays", time: "07:30" },
    actions: [{ kind: "brief", recipe_id: 1 }, { kind: "notify" }],
    enabled: true,
    revision: null,
    nextRunAt: null,
    lastRunAt: null,
    lastMatches: null,
  };
}

function readSchedule(schedule: Schedule): Schedule {
  return { ...schedule, days: schedule.days?.map((day) => day === 0 ? 7 : day) };
}

export function routine(j: J): Routine | null {
  const id = j.get("id")?.int;
  if (id === undefined) return null;
  const schedule = j.get("schedule", "scheduleJson", "when")?.parsed?.value;
  return {
    id,
    name: j.get("name")?.string ?? "Routine",
    viewId: j.get("viewId")?.int ?? null,
    schedule: schedule && typeof schedule === "object" && "kind" in schedule ? readSchedule(schedule as Schedule) : { kind: "manual" },
    actions: (j.get("actions", "actionsJson")?.parsed?.array ?? []).map(routineAction).filter((a): a is RoutineAction => a !== null),
    enabled: j.get("enabled")?.bool ?? true,
    revision: j.get("revision")?.int ?? null,
    nextRunAt: daemonDate(j.get("nextRunAt")),
    lastRunAt: daemonDate(j.get("lastRunAt")),
    lastMatches: j.get("lastMatches")?.int ?? null,
  };
}

export interface DryRun {
  days: { label: string; count: number }[];
  actions: string[];
}

export function dryRun(j: J): DryRun {
  const narrow = new Intl.DateTimeFormat(undefined, { weekday: "narrow" });
  return {
    days: (j.get("days", "perDay")?.array ?? []).map((day) => {
      const date = day.get("date", "day")?.string ?? "";
      const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
      const parsed = match ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3])) : daemonDate(day.get("start", "at"));
      return { label: parsed ? narrow.format(parsed) : date.slice(-2), count: day.get("matches", "count")?.int ?? 0 };
    }),
    actions: (j.get("actions")?.array ?? []).map((a) => a.get("summary", "text", "result")?.string ?? a.string).filter((s): s is string => s !== undefined),
  };
}

/** The reading state before a mark, so that the mark can be taken back. */
export interface Previous {
  id: number | null;
  read: boolean;
  starred: boolean;
  later: boolean;
}

export function previous(j: J): Previous {
  return {
    id: j.get("id", "entryId")?.int ?? null,
    // A state is set when its time is.
    read: j.get("read")?.bool ?? j.get("readAt") !== undefined,
    starred: j.get("starred")?.bool ?? j.get("starredAt") !== undefined,
    later: j.get("later")?.bool ?? j.get("laterAt") !== undefined,
  };
}

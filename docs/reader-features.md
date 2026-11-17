# Views, briefs and routines

This document specifies saved views, recipes, briefs, answers, routines, catch-up and the Activity line: what each does, the operations that serve it, and how the macOS GUI presents it. Interface rules are in [design-rules.md](design-rules.md); the boards are on the [v2 design page](https://app.paper.design/file/01M6R7CJ81MKH0TMWJ8KNC6QGX/p-9-0). Every capability below is one set of operations in `src/ops.zig`, so the socket, CLI and MCP reach it in the same way as the GUI.

The longer-term design in [next-phase.md](next-phase.md) and [aggregator.md](aggregator.md) goes further (story clustering, per-feed refresh policies, closed-window notification delivery). Where this document and those differ, this document describes what is built and those describe what is planned.

## Concepts

| Concept | Question it answers | Stored as |
|---|---|---|
| Rule | Which articles? | JSON validated by the pure module `src/selector.zig` |
| View | A rule with a name, in the sidebar | `views` |
| Recipe | How should a brief or answer be written? | `recipes` with immutable `recipe_revisions` |
| Writer | Which installed agent writes it? | `config.json` under `ai`, detected on `PATH` |
| Brief | A cited summary of a rule's articles | `artifacts` (kind `digest`) with `artifact_sources` |
| Answer | A cited reply to a question about your feeds | `artifacts` (kind `answer`) |
| Routine | When / Look in / Then | `routines` and `routine_runs` |
| Job | Background work shown in Activity | `jobs` |

Opening a view never calls a model. Only `briefs.run`, `ask.run` and routines with a brief action do, and each records which writer, recipe revision and articles it used.

## Rules

A rule is a JSON object. Every field is optional; an empty rule matches every article.

```json
{
  "feeds": [3, 7],
  "folders": [2],
  "state": "unread",
  "words": "storage engine",
  "any_words": false,
  "host": "example.com",
  "subdomains": true,
  "path_prefix": "/blog/",
  "exclude_path_prefix": ["/blog/jobs/"],
  "within_days": 7
}
```

- `feeds` and `folders` together form the scope. A folder includes its descendants. Omitting both means all feeds.
- `state` is `any`, `unread`, `starred` or `later`.
- `words` matches title and body through the full-text index. With `any_words` false every word must appear; with true, any one of them. Words are tokens, never query syntax: quotes, operators and `*` are treated as text.
- `host` matches the article's own address, not the feed's. `subdomains` true also matches `*.host`. Articles with no address never match a host or path condition.
- `path_prefix` and `exclude_path_prefix` match whole path segments from the start of the path, after the address is normalized by `url.zig`. Query strings and fragments are ignored.
- `within_days` is a rolling window from the time of the request, 1 to 3650.

Validation rejects unknown fields, empty strings, more than 64 feeds or folders, words longer than 200 bytes and ids that do not exist. Rules are never turned into SQL text: `store` binds every value as a parameter.

`selector.sentence` renders a rule as the sentence the GUI shows and edits: "Unread from Engineering about storage engine, last 7 days."

## Operations

Tiers follow [api.md](api.md): `read` inspects, `annotate` changes reading state, `manage` changes definitions or starts model work.

| Operation | Tier | Purpose |
|---|---|---|
| `views.list` | read | Views in sidebar order, with unread and total counts |
| `views.get` | read | One view with its rule and sentence |
| `views.preview` | read | Entries and count for an unsaved rule, paged like `entries.list` |
| `views.put` | manage | Create, or update with `expected_revision`; returns the view |
| `views.move` | manage | Set sidebar position |
| `views.remove` | manage | Fails with `kind: "in_use"` and the routine ids unless `detach` is true |
| `entries.list` | read | Accepts `view_id` or `rule` in addition to its existing filters |
| `entries.mark` | annotate | Accepts `later`; returns the previous state so a client can undo |
| `entries.mark_many` | annotate | Set read, starred or later on up to 1000 ids; returns previous states |
| `recipes.list` / `recipes.get` | read | Recipes, current or a given revision |
| `recipes.history` | read | Revisions with time and note |
| `recipes.put` | manage | New revision; `expected_revision` mismatch fails with `kind: "revision_conflict"` and the current text |
| `recipes.reset` | manage | Make the built-in text current again, as a new revision |
| `writers.list` | read | Codex and Claude Code: cached availability, version, checked time, selected |
| `writers.check` | manage | Run the writer's version probe and record the result |
| `briefs.run` | manage | Queue a brief for a view or rule, with a recipe; returns the job |
| `briefs.try` | manage | Same, with unsaved recipe text; the result is not listed as a brief |
| `briefs.list` / `briefs.get` | read | Briefs, newest first; one brief with blocks, citations and provenance |
| `ask.run` | manage | Queue an answer to a question over a view or all feeds |
| `answers.get` | read | One answer with blocks and citations |
| `routines.list` / `routines.get` | read | Routines with their next run |
| `routines.put` / `routines.remove` | manage | Create, edit and delete |
| `routines.dry_run` | read | What a routine would have done over the last 7 days, without doing it |
| `routines.run` | manage | Run now |
| `routines.runs` | read | Past runs with matches and per-action results |
| `jobs.list` | read | Running and recent jobs for the Activity popover |
| `jobs.cancel` | manage | Cancel a queued or running job |

Every change appends an event: `view.changed`, `recipe.changed`, `routine.changed`, `job.changed`, `artifact.new`, `routine.notify`, `entry.state`.

## Writers

A writer is an installed agent command line. Fyke ships adapters for Codex (`codex exec`) and Claude Code (`claude -p`). It runs the writer:

- in a new empty directory under the data folder, removed afterwards;
- with the task on standard input: the fixed template, the recipe text, and the selected articles as numbered sources with their entry ids;
- with a time limit (default 180 s) and a 1 MiB output limit;
- without inheriting Fyke's own MCP server, so the writer cannot change Fyke while writing;
- found on a search path made of the daemon's own `PATH`, the `PATH` of the owner's login shell, `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, because a daemon started by the app or at login inherits only the system folders;
- as one process tree: on Windows a job object ends the writer and everything it started when the time limit passes or the job is cancelled.

The writer must return JSON: `{"title": "...", "sections": [{"heading": "...", "claims": [{"text": "...", "sources": [12, 40]}]}]}`. Fyke checks that every claim cites at least one id that was in the input, converts the result to blocks, and stores the artifact, its sources and the event in one transaction. Output that fails the check is retried once and then fails the job with the reason. Citations prove traceability, not truth; the GUI keeps every source one hover away.

`FYKE_WRITER_CMD` replaces the writer with any command that speaks the same contract. The tests use it with a stand-in written in Python.

Codex uses `--output-schema` and `--output-last-message`; Claude runs with an empty explicit MCP configuration and no tools. `writers.list` probes lazily once per daemon start and caches availability, version and `checked_at` in memory.
`writers.check` refreshes one probe and saves its timestamped result under `ai.checks`. The owner selects a writer with `config.set` under `ai.writer`.

Selection is bounded: at most 60 articles and 120 000 characters of text, newest first. A brief records how many matching articles were left out, and the GUI says so.

## Recipes

A recipe is Markdown that controls focus, tone, length and structure. The fixed template around it (output format, citation rule, the instruction to treat article text as data) is not editable and has its own version number. Each save creates a revision; a brief records the revision it used and keeps showing that text after later edits. Fyke ships one built-in recipe, "Morning brief".

## Routines

A routine has three parts, shown as three lines in the editor:

- **When**: `manual`, `daily` at a time, `weekdays` at a time, or `weekly` on chosen days at a time, in the computer's time zone.
- **Look in**: a view.
- **Then**: any of: write a brief with a recipe, notify, mark the matches read, star them, add a tag.

The daemon's scheduler runs due routines at startup, on changes and within 60 seconds while idle. A spring daylight-saving gap advances a missing time to the first valid minute; a repeated autumn time runs once. A first run captures all matching entries. A run first records its matches (articles in the view that arrived since the routine's last run), then performs each action and records its result. A brief action queues a separate writing job over those captured IDs and records that job ID. Marking read sets an explicit value and never toggles, so a retried run cannot undo a later manual change. If the computer was asleep through several occurrences, one run catches up. Two runs of one routine never overlap.

`routines.dry_run` evaluates the view over the last 7 days, over the current local calendar day and the preceding six days, and reports matches per day and the configured actions. Day boundaries follow daylight-saving changes.

Notify appends a `routine.notify` event. The GUI turns it into a system notification while it is running. Delivery with every window closed is planned.

## Catch-up and undo

`later` is an independent flag beside read and starred; setting it does not implicitly mark an article read. Catch-up walks a view's unread articles one at a time: Skip (←) marks read, Later (↓) marks later, Read now (→) opens it. Every mark returns the previous state, and the GUI keeps an undo stack (⌘Z) for the session.

## macOS GUI

The GUI follows [design-rules.md](design-rules.md):

- **Sidebar**: 32 pt rows with 14 pt icons, indent `10 + 22 × depth`, sections for reading destinations, Views and Feeds, and one status line at the foot that opens the Activity popover.
- **Search and Save as view**: search shows results in the list; ⌘S saves the search as a view and shows its rule as an editable sentence.
- **Today**: the newest brief, read like an article, each claim with numbered citations. Hovering a citation shows the source; a "Made with" footer names the writer and recipe revision and opens the recipe.
- **Recipe**: opens in place with Edit, Try it and History.
- **Routine editor**: When / Look in / Then, a dry run on the last week, and Run now.
- **Ask**: a question box over a view or all feeds, a cited answer, follow-up, and "Make it a routine".
- **Catch-up**: the triage mode above.
- **⌘K**: a palette of every command and destination.
- **Settings**: a destination of the main window, not a window of its own. ⌘,, the gear at the sidebar's foot, the palette and "More in Settings" open it over the list and reader panes with the sidebar still showing; Esc, or any other destination, returns to the place it covered with its article and selection intact. General, Reading, Agents and Data are tabs in its header, and each tab's settings are plain rows in the reading column.
- **Settings · Agents**: writer choice and status, and a ready-to-paste MCP configuration. "Make changes" picks the `--tier` written into that configuration: Never (`read`), Reading state only (`annotate`) or Everything (`manage`). Fyke has no per-change approval prompt; an agent's MCP client decides whether to ask before calling a tool.
- **States**: writing, failed and empty states are inline, say what is safe, and offer one next action. Bulk changes show an undo toast instead of a confirmation.

## Checks

| Check | Covers |
|---|---|
| `zig build test` | Rule validation and sentences, store queries for every rule field, recipe revisions and conflicts, citation validation, routine scheduling with an injected clock (daylight saving, missed occurrences) |
| `tools/e2e_features.py` | Every operation above over the socket and MCP with a stand-in writer: views and counts, previews, briefs and failed output, cancellation, routines, dry runs, undo |
| `tools/e2e_gui.py` | Key presses and clicks through each screen, with snapshots |

The concrete operation parameters, defaults, result shapes and revision-conflict errors are documented in [api.md](api.md#views-writing-and-routines). Normalized address columns are indexed by host; measurements at the architecture's million-entry target are planned.

### Measured

On 2026-11-17, a MacBook Air with Apple M5 (10 cores), 24 GB RAM and macOS
27.0.1 ran Zig 0.17.1's default Debug build. `tools/measure_views.py` ingested
100,000 synthetic articles across 100 feeds through the daemon, then measured
`views.list` over a persistent local socket with 10 views. All articles were
unread. Each case used one initial request followed by 20 warm requests.

| Rules in the 10 views | Matches per view | Initial | Warm p50 | Warm p95 | Warm max |
|---|---:|---:|---:|---:|---:|
| Exact article host | 1,000 | 17.99 ms | 12.89 ms | 18.83 ms | 22.14 ms |
| All articles | 100,000 | 271.11 ms | 208.82 ms | 249.70 ms | 263.66 ms |

Each view uses the same count query as an unsaved selection. Exact host rules
can seek the normalized-host index. Unscoped rules still scan every matching
entry for each view to compute exact total and unread counts; cost grows with
both collection size and view count. These measurements do not establish a
million-entry latency bound. Reproduce with
`python3 tools/measure_views.py ./zig-out/bin/fyke`.

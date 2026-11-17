# Next phase

Status: proposal. The capabilities below are planned, not implemented. This document proposes sequencing and behavior; it does not replace the milestone status in [roadmap.md](roadmap.md) or accept a platform toolkit decision. Screen coverage, code changes, and Windows-first/Linux-next delivery are mapped in [implementation-plan.md](implementation-plan.md).

## Product direction

Make Fyke useful both for reading everything and for following something specific. A person should be able to select relevant articles, save that selection, and ask for a recurring brief whose instructions they can inspect and change. An agent should manage the same objects through MCP.

The first useful AI release need not wait for embeddings, enrichment of every article, or sophisticated clustering. A bounded selection of articles, exact URL deduplication, and a cited brief can establish the reading experience and runner contract. The broader pipeline in [aggregator.md](aggregator.md) remains planned.

## Current foundation

The daemon already owns polling, storage, configuration, and events. Feed polling adapts to posting rate, publisher hints, failures, and host limits. Clients share the operation registry. The macOS GUI has a Briefing placeholder and transient search, but no saved views or routine editor.

The schema already contains lenses, runners, stories, jobs, artifacts, and artifact sources. Those tables are foundations for planned aggregation, not evidence of a working job queue or runner. Artifacts have a prompt hash, but no retained instruction text or revision history.

Linux and Windows are already targets in `tools/release.py`, and `.github/workflows/ci.yml` defines native build and behavior checks for both. This is repository configuration, not a claim that the latest checks or a fresh-machine installation pass. Native desktop GUIs remain planned.

## Four concepts

| Concept | Question it answers | Example |
|---|---|---|
| Saved view | Which articles do I want to see? | Unread database posts, excluding a URL path |
| Refresh policy | When should Fyke fetch feeds? | Automatic globally; a slower interval for one feed |
| Brief instructions | How should the selected material be explained? | Explain changes, separate claims from opinion, cite sources |
| Routine | When should an action run, and on which selection? | Every weekday at 07:30, brief the database view |

The same selector should serve view previews, reading, and routine inputs. A view changes presentation, without hiding or deleting the underlying articles globally. A routine performs work; merely opening a view performs no model call. Refreshing a feed and generating a brief have separate clocks.

“Routes” do not require another object in the first version. Source selection and routine actions cover the concrete cases. A general workflow graph would add concepts before there is evidence that users need them.

## Saved views

Proposed first-version predicates:

- Feed IDs or folder trees, including all feeds.
- Read and starred state.
- Title or body words, using documented search semantics.
- Article URL host and path, including exclusions.
- A rolling age window and newest-first ordering.

Use a small typed selector with explicit all/any groups and negation. The GUI can initially expose an AND list with an “any of these words” control; MCP receives the same validated representation. Arbitrary SQL and unbounded regular expressions are outside the first version.

Host matching must specify exact host versus subdomains. Path matching must specify prefix versus substring. Match article addresses separately from feed addresses, handle missing URLs explicitly, and define normalization once in the core. A URL rule should not silently match tracking parameters when its label says “path.”

Existing `entries.search` considers a bounded recent set of matching entries. Saved views must not inherit that cap silently: their membership, counts, pagination, and routine inputs need a consistent contract. Keep keyset pagination; measure common predicates before claiming they meet timeline performance budgets.

An editor previews matches before saving. Deleting a referenced view should fail with a list of dependent routines unless those routines are explicitly detached or removed. A changed view affects future runs; queued work retains the selector revision it captured.

Done when a view created through MCP appears in the GUI, edits propagate through events, both surfaces return the same entries, and restart, paging, empty results, missing URLs, and malicious predicate values behave correctly.

## Editable brief instructions

Use the product name **Instructions**, with Markdown as the portable format. An ordinary editable prompt does not need to implement an agent skill package format. Packaging a reusable skill can be a later interoperability feature.

A brief should offer “View instructions,” “Edit a copy,” “Preview inputs,” and “Run.” Ship a readable default; preserve it so restoring the default remains possible. Editing creates a revision rather than rewriting the instructions attached to old briefs.

The editable section controls focus, tone, length, and organization. The daemon retains the output schema, citation checks, limits, and untrusted-content framing as separate constraints. User instructions cannot turn off citation validation or grant tools to the model.

Each run should capture:

- Instruction revision and exact rendered instructions, including the fixed template version.
- Selector revision, selection cutoff, input entry IDs and content revisions or hashes.
- Runner, model, parameters, and resource limits.
- Start/end time, result, errors, and usage when the runner reports it.

A hash alone cannot show what an old brief was told. Retaining the text allows inspection, but does not guarantee identical output from a nondeterministic model. Exact input replay would additionally require retained input text; otherwise show when articles were edited, trimmed, or deleted since the run. Input retention must follow an explicit storage policy rather than grow without bounds.

The daemon owns instruction writes through operations, including import/export of Markdown. A later external-editor workflow should import a revision explicitly or detect conflicting edits. Accept instruction IDs through MCP, rather than allowing a caller to make the daemon read arbitrary filesystem paths.

Done when instructions can be inspected and edited in GUI and MCP, an old brief still displays its original revision, an invalid response never becomes a published artifact, and no AI output is stored in `entries`.

## First AI brief

Start with a manual run over a feed, folder, or saved view. Apply an explicit time window and entry/token limits; group exact canonical URL duplicates without removing source entries. Show what was included and omitted. Do not label a truncated input set as complete coverage.

Reuse the planned lens as the brief configuration and the existing jobs/artifacts concepts. Add instruction revisions and run provenance through schema migrations; do not treat the current unused table shapes as immutable contracts. Keep stories optional in the first brief so clustering can improve independently.

Validate structured claims with citations to entries supplied to that run. Citation ID validation establishes traceability, not factual entailment; readers must still be able to inspect the source. Render output through blocks, label it as AI-generated, and keep tools disabled by default. Empty selections should finish without a model request.

Prioritize the installed **Codex CLI** through the planned `exec` runner. Hosted API runners, local HTTP model servers, other installed agents, and ACP remain later integrations. Use the installed agent's authentication without copying credentials into Fyke's database. Runner setup should check availability and report authentication or compatibility failures before scheduling unattended work.

The locally inspected `codex exec --help` supports noninteractive input on stdin, JSONL events, a final-response JSON Schema, ephemeral sessions, and an explicit working directory. These provide a candidate transport for task input, progress, and structured output; Fyke still validates the result itself. Record the executable version and verify the required capabilities during setup rather than assuming all installed versions support the same options.

Run in a dedicated scratch directory with a controlled configuration. Pass only the selected article context and resolved instructions. Do not inherit unrelated project instructions, hooks, MCP connections, or executable integrations. The first brief does not need the agent to browse or call Fyke tools. A read-only filesystem sandbox alone does not establish those restrictions; proving that the chosen Codex execution configuration enforces the required tool and data boundaries is an integration acceptance gate. Do not substitute unrestricted execution if the installed version cannot enforce them.

The adapter should handle progress, timeout, cancellation, exit status, and bounded output. Show usage only when reported; unknown usage is not zero. Arbitrary executable runner configuration requires manage-level access. A later local HTTP runner needs an explicit trusted endpoint configuration, separate from feed-controlled URLs.

Done when a manual brief shows citations, original instructions, runner identity, errors, and usage; failed validation retries within a bound; cancellation and daemon restart do not publish duplicate artifacts.

## Refresh policies and routines

### Refresh policies

Begin with a global automatic policy and per-feed overrides for automatic, interval, or paused. Folder policies can follow if inheritance proves useful; overlapping saved views should not become competing fetch schedules.

A requested interval is subject to minimum intervals, publisher guidance, backoff, `Retry-After`, and per-host concurrency. Show the effective next fetch and its reason. Reuse the existing claim mechanism so scheduled and manual requests cannot fetch the same feed concurrently.

### Routines

Begin with a source selection, a set of independently enabled actions, and either a manual or daily/weekly trigger. Support all three outcome families in the first routine release:

| Outcome | Planned behavior |
|---|---|
| Collect | Record new matches in a persistent routine collection, with an optional cited brief |
| Notify | Send a grouped desktop notification that opens the collection or completed brief |
| Article actions | Apply explicitly configured tags, star/unstar, or read/unread changes to the captured matches |

A routine can enable any combination, including all three. Live saved-view membership and collected matches are distinct: a collection preserves which entries matched a run, while a saved view continues to reflect current article state. A deterministic watch can collect, notify, and apply article actions without calling Codex.

Capture the match set before performing actions so marking an article read does not remove it from an unread-only run halfway through processing. Persist collection membership and each action's status. Brief generation consumes the captured inputs; article mutations do not depend on its success. A notification links to the collection by default, or waits for the brief if configured to announce a completed brief. A failed brief must not produce a notification claiming it succeeded.

Use an action ledger keyed by run and action, with per-entry identities where needed. Retry failed actions without repeating completed ones. Article mutations must set explicit desired values rather than toggle state, and tag application must preserve tags from other sources. Do not undo a later manual edit when replaying an already completed action. Show partial success and offer retry of failed actions in both GUI and MCP.

Persist notification intent separately from OS delivery, group matches to avoid notification floods, and provide a native delivery path that works with the main window closed. Permission denial or unsupported delivery leaves the collection available and is reported separately from a model failure. An OS delivery acknowledgment is not proof the person saw it; avoid promising exactly-once visible notification delivery across crashes. Per-ingest triggers remain a later extension.

A topic watch needs durable match state, not merely “articles published since the previous run.” Late arrivals can have old publication dates, and full-text extraction can make an existing article match later. Track processed changes and per-routine entry matches; define whether an edited article can alert again. Backfill is explicit and bounded.

Proposed scheduling rules:

- Store an explicit time zone and display the next occurrence. Verify the Zig/OS time-zone integration before promising arbitrary IANA zones on every platform.
- Run once at the first occurrence of a repeated local time; move a nonexistent local time to the next valid instant.
- After sleep or downtime, coalesce missed occurrences into one catch-up run rather than a burst.
- Prevent overlapping runs of the same routine. Persist occurrence identity and claim work transactionally.
- Capture immutable configuration when queuing. Editing affects future work; disabling prevents future occurrences, with cancellation of active work a separate action.
- Advance the match-discovery checkpoint only after captured matches and action intents are durably recorded. Track action completion separately, so failure or cancellation cannot lose pending work and replay cannot repeat completed mutations. Use stable action identities to make retries safe.
- External calls may repeat after a crash between response and local commit. Do not promise exactly-once model billing; publish a given run's artifact at most once.

“Refresh before run” should be an explicit option with a deadline and a report of feed failures. The default brief uses stored articles and displays their freshness. The daemon or installed background service owns execution while the GUI is closed; a closed GUI cannot provide notification delivery by itself.

Done when all three outcome families work together, and restart, offline operation, sleep, clock changes, daylight-saving transitions, notification denial, partial action failure, edits, retries, and cancellation preserve these rules, with the same history available through GUI and MCP.

## API and storage boundaries

Proposed operation families, subject to final naming in the operation registry:

| Operations | Tier | Responsibility |
|---|---|---|
| `views.list/get/preview` | read | Inspect selectors and matching articles |
| `views.put/remove` | manage | Create and edit saved views |
| `instructions.list/get` | read | Inspect current and historical instructions |
| `instructions.put` | manage | Create instruction revisions |
| `lenses.list/get`, `artifacts.list/get`, `jobs.list/get` | read | Inspect brief definitions, outputs, and work |
| `lenses.put/run`, `runners.put`, `jobs.cancel` | manage | Configure and initiate model work |
| `routines.list/get`, `routines.runs`, `routines.matches`, `refresh_policies.list/get` | read | Inspect automation, collections, per-action results, and effective timing |
| `routines.put/remove/run/retry`, `refresh_policies.put/remove` | manage | Change automation and fetching; retry failed actions |

Read access must not incur model charges or change schedules. Artifact publication by an external agent remains a separate annotate-tier operation with validated citations, as planned in [api.md](api.md). Add operation docs and event notifications with each capability. Keep SQL in `store`, all durable writes in the daemon, and selector evaluation independent of client rendering.

## UI structure and cleanup

The [v2 design page](https://app.paper.design/file/01M6R7CJ81MKH0TMWJ8KNC6QGX/p-9-0) draws these features inside the existing three panes, and its rules are recorded in [design-rules.md](design-rules.md). The first-pass page (p-8-0) is superseded. The built subset is specified in [reader-features.md](reader-features.md).

Proposed surfaces:

- **Sidebar:** saved views beneath the built-in reading destinations.
- **View editor:** source scope, filter rows, live results, and save/update actions.
- **Briefing:** brief selection, readable output, sources, freshness, and an instructions/run-details inspector.
- **Routine editor:** source → actions → timing, with collection, notification, and article-action controls and a next-run preview.
- **Routine history:** captured matches, per-action results, partial failures, skipped work, retry/cancel controls, and links to outputs.
- **Feed settings:** refresh override and effective next-fetch explanation.

Design empty, loading, offline, invalid-instruction, budget-exhausted, and stale-output states alongside the successful path. Distinguish the current configuration from the revision that produced a displayed brief.

Treat minor fixes as a bounded stabilization pass, beginning with reproduced issues. Candidate checks are keyboard focus, shortcuts, selection after live updates, daemon reconnects, long titles, light/dark contrast, and error recovery. These are audit targets, not confirmed bugs. Add regression coverage where a concrete failure warrants it.

## Linux and Windows

Keep the Zig daemon and protocol. UI language changes do not require a core rewrite.

| Direction | Proposed stack | Benefit and cost |
|---|---|---|
| Native Linux | Rust + GTK4/libadwaita | Fits the GTK/GNOME ecosystem; adds Rust and a separate client. Test outside GNOME before calling it a general Linux desktop release |
| Native Windows | C# + WinUI 3 | Fits the Windows App SDK and desktop controls; adds .NET/XAML and Windows-specific build and packaging work |
| Shared Linux/Windows alternative | C# + Avalonia | Shares more presentation code; changes the roadmap's native-toolkit direction and still needs platform integration testing |

These are recommendations, not measured winners. GTK documents [language bindings](https://www.gtk.org/docs/language-bindings/) including [Rust](https://www.gtk.org/docs/language-bindings/rust/); GNOME describes [GTK/libadwaita application development](https://developer.gnome.org/documentation/tutorials/beginners.html). Microsoft recommends [WinUI 3 for new Windows applications](https://learn.microsoft.com/en-us/windows/apps/). Avalonia documents [Windows, Linux, and macOS support](https://docs.avaloniaui.net/docs/supported-platforms). Verify current target-version and distribution requirements when implementing.

Prototype the same slice before choosing: connect/start/reconnect the daemon, page a large timeline, render representative blocks, navigate with the keyboard and assistive technology, apply themes and bundled fonts, and package/install/uninstall on a clean machine. Include non-Latin text, links, images on request, code, and large articles. Remote-page viewing must preserve the separation and security requirements in decision 0002; a toolkit's web control is not sufficient evidence by itself.

Measure startup, idle memory, scrolling, and package size. The choice should reflect maintenance effort and the actual reading experience. Record the final toolkit choice in an ADR after the prototypes. Verify core archive releases independently so desktop UI work does not block CLI/TUI/MCP distribution.

## Proposed delivery order

| Stage | Deliverable | Acceptance gate |
|---|---|---|
| A | Stabilization and release inventory | Reproduced bugs triaged; current Linux/Windows check results and fresh-install gaps recorded |
| B | Shared selectors and saved views | GUI/MCP parity, consistent counts and paging, restart persistence |
| C | Editable instructions and manual cited brief through installed Codex | Capability/setup checks, controlled execution, revision provenance, and failed-output handling work |
| D | Refresh overrides and durable routines with collection, notifications, and article actions | All outcomes work together; closed-window delivery, catch-up, restart, partial retries, and no duplicate publication |
| E | Richer aggregation | Measured improvements from stories, ranking, and optional enrichment over the simple brief |
| Separate track | Platform GUI prototypes, then one complete client | Toolkit ADR based on measured reading, accessibility, packaging, and maintenance results |

The Windows prototype can proceed alongside shared feature work. Complete the Windows GUI release gate before starting the Linux GUI. This proposal brings a narrow part of runners ahead of the full story-clustering milestone; implementation requires updating the roadmap and aggregator design consistently.

## Open choices

- Which installed Codex versions and execution configuration meet the brief's isolation and structured-output requirements?
- Do the proposed native toolkits pass the Windows prototype and subsequent Linux prototype gates?
- Which concrete UI bugs should lead the stabilization pass?
- What input retention is acceptable for inspecting or replaying historical briefs?

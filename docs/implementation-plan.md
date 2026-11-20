# Next phase implementation

Status: planned. No capabilities in this plan are implemented by this document. Product behavior is specified in [next-phase.md](next-phase.md). Existing milestone results remain in [roadmap.md](roadmap.md).

The delivery priority is shared daemon capabilities, a complete Windows GUI, then a Linux GUI. Keep the existing macOS client working as the first reference client for new operations. Linux core correctness remains covered by CI throughout; Linux GUI implementation follows the Windows release gate.

## Design inventory

The [v2 design page](https://app.paper.design/file/01M6R7CJ81MKH0TMWJ8KNC6QGX/p-9-0) holds the screens; its rules are in [design-rules.md](design-rules.md). Samples on the boards are illustrative, not measured results.

| Boards | Flow | Implementation boundary |
|---|---|---|
| 00 | Principles, measurements, sidebar indent rule | [design-rules.md](design-rules.md) |
| 01–04 | Sidebar, search and Save as view, Today brief with citations, recipe in place | Rules, views, briefs, recipes, writers |
| 05 | Routine: When / Look in / Then, dry run | Routines, scheduler, run records |
| 06 | Activity popover | Jobs and cancellation |
| 07 | ⌘K palette | Client only |
| 08 | Ask your feeds | Answers with citations |
| 09 | Catch-up triage | `later` state, bulk marks with undo |
| 10 | Settings · Agents and MCP | Writer detection, MCP configuration |
| 11–12 | Windows 11 and Linux GNOME shells | Platform clients |
| 13 | Writing, failed, empty and undo states | Every surface |

## Existing implementation to preserve

- `src/ops.zig` declares operations, parameter docs, types, and tiers. Socket and MCP dispatch share `all`.
- `src/store.zig` owns SQL, migrations, list/search queries, marks, and events. `build.zig` embeds five migrations, and the migration list is explicit in `store`.
- `src/service.zig` owns worker/scheduler state. `src/pipeline.zig` owns ingest; pure parsers remain free of I/O.
- `src/client.zig` and `src/daemon.zig` use newline-delimited JSON-RPC over `AF_UNIX`, including on Windows. Reuse the protocol before introducing another transport.
- `src/main.zig` resolves Windows data under `%LOCALAPPDATA%\Fyke` and follows the `location` pointer used by data moves. Other systems retain the existing home-directory layout.
- `src/windows_startup.zig` uses `HKCU` Run for sign-in startup, through the per-user supervisor in `src/supervise.zig`. `src/systemd.zig` and `src/launchd.zig` use service managers.
- `gui/Sources/Reader/Daemon.swift` provides socket calls and events. `AppModel.swift`, `Sidebar.swift`, and `RootView.swift` own navigation/view state; `ReaderPane.swift` renders blocks.
- `gui/tokens.css` is exported from Paper. `tools/gen_tokens.py` generates Swift tokens. Do not edit `Tokens.swift` or silently change the bundled reading default.
- Windows CI compiles the WinUI scaffold and runs the client and view-model suites. Desktop execution and GUI packaging are tracked in [the Windows delivery plan](windows-gui.md).

## Shared core changes

### Selectors and saved views

Add a pure `src/selector.zig` module for the typed selector, validation, normalization, and limits. Keep SQL generation/binding and execution in `store`. Reuse `url.zig` normalization rather than adding client-specific URL matching.

Extend timeline filtering with the selector or a saved-view reference. Define count and preview operations over exactly the same predicate. Include selector revision and rolling-window cutoff in cursors where required; reject a cursor reused with a different query. Preserve `(sort_at, id)` keyset order.

Add versioned view definitions and ordered sidebar placement. Use compare-and-set revisions for edits. Definitions referenced by queued work are captured; deleting a live referenced view returns a structured dependency error. Do not feed arbitrary SQL or regular expressions into the first selector API.

Tests should cover host/subdomain and path boundaries, missing addresses, Unicode terms, SQL-like input, folder descendants, state changes, consistent counts/paging, deleted dependencies, and the existing search cap. Measure at the existing reference scale before setting a saved-view latency claim.

### Instructions, brief configurations, and artifacts

Keep lenses as brief configurations. Add immutable instruction revisions, with built-in defaults represented separately from user copies. Save requires an expected revision; a conflict returns the current revision and preserves the caller's draft. Import/export transfers Markdown text, not arbitrary daemon-readable paths.

Add a narrow `src/aggregate.zig` coordinator for selection, exact canonical-link grouping, resource limits, task assembly, and validation. Separate pure output validation from runner I/O. Do not require embedding/enrichment jobs to produce the first brief.

Capture instructions, fixed-template version, selection revision/cutoff, selected entry revisions, runner configuration revision, and reported model in a run record. Retain bounded input Markdown if exact input inspection/replay is offered; otherwise label historical input changes explicitly. Define input/log retention before shipping background schedules.

Validation checks the structured claim shape and citation membership, produces blocks, and commits artifact, citations, completion, and event in one transaction. Use a unique run-to-artifact relation so a recovered completion cannot publish twice. Citation validity does not prove the claim's truth.

### Codex runner

Add `src/runners.zig` and a Codex adapter, keeping subprocess details outside aggregation policy. First implement a controlled fake executable with the same transport contract for tests. Then validate the installed Codex CLI on each target OS; no hosted API is required for this milestone.

The local CLI inspection found noninteractive stdin, JSONL progress, `--output-schema`, `--ephemeral`, and working-directory controls. These are candidate mechanisms, not a version-independent promise. Compatibility checks must establish the actual options and execution restrictions supported by the installed version.

Use explicit argv, bounded input/output, an isolated task directory, and controlled inherited configuration/environment. Validate which instructions, hooks, plugins, MCP servers, and tools remain available. An empty working directory and a read-only sandbox are insufficient evidence of isolation. Fail the setup check if the required boundaries cannot be enforced. Authentication stays under Codex's supported credential mechanism; do not print or copy credentials.

Drain progress and errors while waiting for completion. Propagate cancellation to the process tree, not only the immediate process. Windows requires a tested process-tree mechanism; a Job Object is a candidate. Record a bounded diagnostic log, distinguish sign-in, launch, timeout, cancellation, nonzero exit, output-limit, and validation failures. Unknown token usage remains unknown.

### Durable jobs and routines

Add `src/jobs.zig` for leases, retry policy, and cancellation and `src/routines.zig` for occurrence calculation and action orchestration. Integrate wakeups into `Service`; do not create a scheduler in a client. Keep time arithmetic testable with an injected clock. Establish portable time-zone rules and a data source before exposing arbitrary named zones.

Persist an occurrence identity, configuration snapshot, input capture, match checkpoint, and independent action records. Capture matches and action intents transactionally before advancing discovery. Late entries and content/full-text updates must enter discovery without relying on publication time alone.

Article actions set desired state, never toggle. Apply batches through store transactions and append events. Tags already have source identity in `entry_tags`; add operations preserving user/other-routine sources. Retrying a completed action cannot overwrite subsequent manual changes.

Notifications use a durable outbox with stable IDs and a native delivery adapter. Claim/ack/report delivery through the daemon API. A disconnected GUI is not a notification sender. Exactly-once publication is enforceable locally; exactly-once model charging or visible OS notification delivery is not promised.

### Refresh policy

Add stored global/per-feed overrides and expose requested policy separately from effective due time and reason. Extend the existing scheduler calculation and claim path. Keep rate limits, `Retry-After`, publisher hints, host concurrency, and existing adaptive behavior. No parallel scheduling loop and no fetches initiated by a view preview.

### Migrations

Create new numbered migrations after 0005; do not modify existing migrations. The proposed groups are views/revisions, instructions/run provenance, and routines/actions/outbox/refresh overrides. Final numbering follows the actual implementation order.

Review existing `jobs`, `lenses`, `artifacts`, and citation tables before adding replacements. Extend them where the semantics fit. Foreign keys and deletion behavior must preserve historical provenance without blocking explicit user deletion indefinitely. Update embedded schema registrations in `build.zig`, the migration list in `store`, schema docs, and upgrade fixtures together.

## Operation contract

Names below are proposed. Every operation needs parameter docs, tier enforcement, bounded results, and events where it changes observable state.

| Tier | Planned additions |
|---|---|
| read | `views.list/get/preview`, `instructions.list/get`, `lenses.list/get`, `runners.list/get/status`, `jobs.list/get`, `artifacts.list/get`, `routines.list/get/runs/matches`, `refresh_policies.list/get` |
| annotate | `entries.tag`, cited external `artifacts.put` |
| manage | `views.put/remove`, `instructions.put`, `lenses.put/run`, `runners.put/check`, `jobs.cancel`, `routines.put/remove/run/retry`, `refresh_policies.put/remove` |
| native delivery, socket only | Notification claim/ack/status operations, hidden from MCP and bound to the intended trusted delivery connection |

Split runner checks: `runners.status` reports cached capability/status; `runners.check` launches a probe and belongs to manage. The local socket currently trusts the owner, so design a concrete bridge registration mechanism before claiming exclusive consumer identity.

Errors need stable kinds for revision conflict, dependent routines, incompatible runner, authentication required, validation failure, resource limit, unavailable zone, partial action failure, and delivery denial. A reconnect must not blindly repeat a mutating request after a lost reply. Add request/run identities for operations that create chargeable or repeated work.

Keep CLI, TUI, socket, and MCP able to inspect and manage these definitions. Native clients render the same records. Add events for definition revisions, job progress/completion, routine action state, artifact publication, and refresh-policy changes. Define replay-gap recovery when event retention no longer covers a client's sequence.

## Windows first

### Proposed stack and project

Use C# with WinUI 3 for the first prototype, in a proposed `gui-windows/` project. This follows the native-toolkit direction; finalize the toolkit ADR only after the reading/IPC prototype passes. Preserve the macOS client rather than moving it into a shared UI framework.

Use native navigation/controls, Inter/Newsreader/JetBrains Mono where the design calls for them, and virtualized article lists. Implement block rendering using native text, inline links, lists, code, tables, and images loaded on request. Do not turn the article reader into raw HTML in WebView2. Initially open remote pages in the default browser; an embedded web viewer is a separate feature requiring the security work in decision 0002.

Create a C# protocol client with typed DTOs, cancellation, framing/body limits, separate event/long-running connections, and API-version compatibility handling. Prototype `.NET` `AddressFamily.Unix` against Fyke's current Windows socket. Use `FYKE_HOME` and the existing location pointer. Do not introduce named pipes or TCP without a demonstrated compatibility problem and an ADR.

### Windows delivery slices

The [Windows delivery plan](windows-gui.md#remaining-launch-work) tracks current evidence and the smaller review units within these slices.

| Slice | Planned changes | Gate |
|---|---|---|
| W0 | Native test machine/VM; C# AF_UNIX + event spike; path resolution | Start, connect, kill/reconnect; Unicode/space/long paths; no second writer |
| W1 | Window, sidebar, virtualized list, blocks, keyboard/focus, themes | Daily reading, search, marks, links, images-on-request; Narrator and DPI checks |
| W2 | Add/discover feeds, folders, OPML, settings, storage/data move | Existing client capabilities usable; data pointer and service paths remain consistent |
| W3 | Saved views, brief setup/editor/output/history, jobs, routine editors | Screen inventory and socket/MCP contracts agree; no UI-only mutations |
| W4 | Per-user background lifecycle and notification bridge | Main window closed; crash recovery; denied delivery; activation opens the correct run |
| W5 | Installer, updates, uninstall, release CI and clean-user acceptance | One complete supported Windows desktop release before Linux GUI work |

W0/W1 can begin while shared features are implemented. W3 waits for their operation contracts and fixtures. W4 waits for the durable outbox/action model.

### Lifecycle, notifications, and packaging

Retain sign-in/session scope: no requirement for a machine-wide Windows service or administrator rights. The Run key starts a small per-user supervisor (`fyke daemon --supervise`), chosen over a Task Scheduler entry because it needs no other tool and behaves the same in tests. It restarts the daemon after a crash with growing delays and ends on a clean stop. Reinstalling stops the running daemon and waits for its lock before starting the new one, so two never compete. Lock ownership still enforces one daemon.

Use a small native notification delivery mode/helper that connects to the daemon outbox. It presents local app notifications and routes activation by stable run IDs. Keep domain state and all SQLite access in the daemon. Microsoft documents [desktop app notifications](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/) and [registration/activation for console applications](https://learn.microsoft.com/windows/apps/develop/notifications/app-notifications/app-notifications-console). Task Scheduler documents [failure restarts](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-restartonfailure-settingstype-element); the prototype still needs to prove the intended Fyke lifecycle.

The first direct-download GUI release uses an unpackaged per-user Inno Setup installer that bundles the compatible `fyke.exe`, fonts and the self-contained GUI, which also posts notifications (`--notify`). CI installs, upgrades and uninstalls it on Windows (`tools/e2e_installer_windows.py`); see [Installer](windows-gui.md#installer). Signing and a clean-machine run outside CI remain. MSIX/Store distribution can follow once packaged identity, data location, CLI availability, service registration, and update behavior are proven. Microsoft documents [unpackaged deployment requirements](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/unpackage-winui-app?tabs=csharp).

Use a stable per-user installation path. Update GUI/helper/core as one compatible set; stop background processes before replacing executables, preserve data, and restart according to the user's preference. Uninstall removes startup/notification registration but retains reading data unless the user explicitly chooses deletion. Signing credentials and published distribution require a separate release action; preparing builds does not publish them.

Start with the existing x64 core target. Windows ARM64 is a separate target/validation gate, not an implicit benefit of C#. Define the supported Windows version from the selected stable SDK and native test matrix; do not claim all Windows 10 versions from an untested GUI build.

### Windows checks

Extend the existing Windows CI with GUI build/package checks and deterministic fake-runner/outbox tests. Add UI automation against the actual WinUI app using Windows UI Automation; the existing macOS key-playback test does not cover Windows.

Manual/native acceptance includes Narrator, keyboard-only use, 100/150/200% scaling, multiple monitors, light/dark/high contrast, IME/non-Latin text, virtualized scrolling, notifications with no main window, service crashes, sign-in, upgrade, uninstall, and data moves. Use an isolated `FYKE_HOME` and test registry/task names. Keep OS notification delivery tests separate from deterministic domain tests.

Inspect ACLs for default and user-selected data directories and socket access. `platform.makePrivate` currently does nothing on Windows and relies on inherited profile permissions; that assumption needs validation when a user chooses another location. Do not claim owner-only security merely because a POSIX mode appears in code.

## Linux next

Begin the Linux GUI after W5. Use Rust with GTK4/libadwaita as the prototype stack in proposed `gui-linux/`; finalize it after testing the reading experience on both GNOME and KDE. Reuse wire fixtures and behavioral scenarios from Windows, not C# presentation code.

Implement the same API client behavior and native block renderer, then the shared feature inventory. Keep daemon and GUI binaries separate. Preserve the existing data layout initially; an XDG migration is a separate reversible migration project, not a packaging side effect. Respect `FYKE_HOME`, socket path limits, and data moves.

| Slice | Planned work | Gate |
|---|---|---|
| L0 | GTK reading/IPC prototype | Socket/events, native blocks, fonts, accessibility, virtualized lists |
| L1 | Full reader and shared feature flows | Same definitions, state, and errors as Windows/macOS/MCP |
| L2 | Desktop integration | systemd user service, D-Bus notifications, activation and default-browser links |
| L3 | Distribution and release | Native install/update/uninstall plus GNOME/KDE and Wayland/X11 acceptance |

Use the existing `systemd --user` integration. No boot-before-login claim without explicit lingering configuration. A notification bridge needs the user's desktop bus; a healthy headless daemon does not imply notification delivery is available. Preserve pending notification/error status while keeping matches and briefs readable.

Start with a native package or documented install layout on a declared reference distribution, including GTK/libadwaita runtime requirements. Flatpak is a later packaging track: the daemon socket and installed host Codex cross its sandbox boundary. [Flatpak's sandbox rules](https://docs.flatpak.org/en/latest/sandbox-permissions.html) restrict host files and processes by default. Do not solve that by silently granting broad home/process access. Define the host-daemon connection and permissions before advertising Flatpak support.

Retain x86_64/aarch64 core archive coverage. A GTK GUI has dynamic runtime dependencies even when the Zig core archive is static. Test Orca, keyboard focus, fractional scaling, missing fonts, GNOME/KDE notifications, no-systemd/no-session-bus errors, and clean installs on the explicitly supported distributions.

## Reviewable implementation batches

1. Selector semantics and fixtures, then view migrations/operations/events, then macOS view screens and MCP parity checks.
2. Instruction revisions and lens CRUD, then fake runner/jobs, then Codex compatibility spike and cited artifact publication, then brief screens.
3. Match capture/action ledger and tag operations, then deterministic routine actions, then time-zone/occurrence scheduling and refresh overrides, then native notification bridges.
4. Windows W0–W5. Avoid holding unrelated shared-core fixes until the entire GUI is complete.
5. Linux L0–L3 after the Windows desktop release gate.
6. Story clustering/ranking, richer enrichment, runner comparisons, and ACP as independently measured later capabilities.

Open a tracked issue before implementation batches larger than a fix, as required by CONTRIBUTING. Each batch should include the operation contract, migration if needed, failure behavior, and relevant checks. Do not renumber implemented migrations to match this outline.

## Verification and unresolved choices

Planning evidence: repository source/workflow inspection, installed Codex CLI help, static Paper screenshots, and official platform references. No Windows/Linux GUI prototype, Codex model request, native install, UI automation, performance measurement, or implementation test was run for this plan.

Remaining decisions are the enforced Codex execution configuration, input/log retention, portable named-zone support, Windows crash supervisor/installer, minimum supported OS/distribution versions, and final toolkit ADRs. The delivery order is settled: Windows GUI first, Linux GUI next.

# API and agent integration

Everything outside the daemon goes through one set of operations. This document defines them and how each protocol maps on to them.

![Agent integration](diagrams/agents.svg)

*Agents reach us through MCP or the CLI, and we reach agents through runners; ACP closes the loop by giving a spawned agent our MCP server.* ([source](diagrams/agents.mmd))

## Which standard does what

| Standard | Direction | Role here | Priority |
|---|---|---|---|
| **CLI with `--json`** | Agent calls us | Works with anything that has a shell. Cheapest and most universal | First |
| **MCP** | Agent calls us | Structured tools and resources for Claude Code, Codex, Cursor and others | First |
| **Plain files** | Agent reads us | Documented SQLite schema and `AGENTS.md`, so an agent can understand and query with no integration at all | Free |
| **ACP** | We call agents | We act as the client: launch any ACP agent, stream its work into our UI | Later |
| **`exec` runner** | We call agents | Runs any script, so any agent SDK works in any language | With aggregator |

MCP and ACP are different layers, not rivals. MCP connects an agent to tools. [ACP](https://agentclientprotocol.com) (Agent Client Protocol, from Zed) connects a client application to an agent, the way LSP connects an editor to a language server. A typical agent is an ACP server to its client and an MCP client to its tools at the same moment.

Not used: A2A (agent-to-agent, no need here). Note that "ACP" also once meant IBM's Agent Communication Protocol, which is unrelated.

## Operation registry

An operation is declared once: name, tier, input type, output type, description. From that one declaration come the socket method, the CLI subcommand, the MCP tool, the JSON Schema and the generated reference doc.

Pagination is keyset-based: list results return `next_cursor`.

### Read tier

| Operation | Purpose |
|---|---|
| `feeds.list`, `feeds.get` | Subscriptions, health, last error |
| `entries.list` | Timeline, filtered by feed, folder, tag, state, date range |
| `entries.get` | One entry. `format`: `blocks`, `markdown` or `text` |
| `entries.search` | Words, with snippets, newest first, filtered by `unread_only` and `since_days`. Also matches entries of feeds whose name or host fits every word. Relevance order is not built: ranking every match of a common term takes around a second at 1,000,000 entries |
| `entries.similar` | Nearest neighbors by embedding |
| `stories.list`, `stories.get` | Aggregated stories |
| `artifacts.list`, `artifacts.get` | Summaries and digests, with citations |
| `lenses.list`, `jobs.list` | Aggregator configuration and status |
| `stats.get` | Counts and storage |
| `schema.describe` | Annotated database schema |
| `db.query` | Read-only SQL, row and time limited, on a `query_only` connection |
| `events.since` | Poll the change feed by sequence number |

`db.query` is deliberate, and it is the recommended path for agents. Opening the file directly is possible, but `sqlite3 -readonly` fails with error 14 after a clean daemon shutdown; use `file:rss.db?immutable=1` only while the daemon is stopped.

Registered operations cover the common paths, and SQL covers every question nobody predicted, which is what "access all the information" requires.

### Annotate tier

| Operation | Purpose |
|---|---|
| `entries.mark` | Read, starred, hidden |
| `entries.tag` | Add or remove tags, recorded with their source |
| `notes.add` | Attach a note |
| `artifacts.put` | Store agent output. Requires citations. It then appears in the Briefing view |

`artifacts.put` lets an external agent, run by you on your own schedule, publish into the GUI with no runner configured.

### Manage tier

Built: `feeds.add`, `feeds.remove`, `feeds.refresh`, `feeds.refresh_all`, `opml.import`, `daemon.stop`, `daemon.housekeep`.

Planned: `feeds.update`, `folders.*`, `lenses.put`, `lenses.run`, `runners.put`, `jobs.cancel`.

`rss ops` lists what exists now. `opml.export` and `ops.list` are in the read tier.

### Socket only

`events.subscribe`: a live stream for the GUI and TUI, starting from `since_seq`.

## Permission tiers

| Tier | Grants | Default for |
|---|---|---|
| `read` | Read operations | `rss mcp`, ACP-launched agents |
| `annotate` | Plus marks, tags, notes, artifacts | Opt in: `rss mcp --tier annotate` |
| `manage` | Plus changing subscriptions and config | CLI, GUI, TUI. Opt in for MCP |

Tiers are enforced in the `ops` layer on each call, not in the adapters. The reason is in [Security](architecture.md#security).

## Socket protocol

JSON-RPC 2.0, newline-delimited, over the Unix socket at `$RSS_HOME/rssd.sock`. This is the same framing MCP specifies for stdio, and MCP recommends it for custom stream transports, so `rss mcp` needs no second framing layer.

```json
{"jsonrpc":"2.0","id":1,"method":"entries.search","params":{"query":"zig parser","limit":10}}
{"jsonrpc":"2.0","id":1,"result":{"items":[],"next_cursor":null}}
{"jsonrpc":"2.0","method":"event","params":{"seq":8841,"type":"entry.new","subject_id":5120}}
```

Errors use JSON-RPC error objects with stable numeric codes and a `data.kind` string.

| Code | Meaning |
|---|---|
| `-32700` | Line is not JSON |
| `-32600` | Not a valid request |
| `-32601` | Unknown method |
| `-32602` | Wrong parameters |
| `-32001` | Operation is above this connection's tier |
| `-32000` | Operation failed. `data.kind` says why, such as `NoSuchEntry` |

Requests are limited to 1 MiB per line. A longer one closes that connection.

`events.subscribe` takes `since_seq` and turns the connection into a one-way stream, so a client keeps a second connection for requests. After a reconnect, it resumes from its last sequence number.

`connection.restrict` takes a `tier` and lowers this connection for good. New connections start at `manage`, since anything that can open the socket already owns the data. `rss mcp` will restrict itself before accepting any agent request.

## CLI

Human output on a terminal, JSON with `--json` or when piped. Exit codes are stable.

```bash
rss add https://example.com/feed.xml
rss list --unread --feed 12 --limit 20
rss search "zig parser" --json
rss show 5120 --format markdown
rss mark 5120 --read
rss import subscriptions.opml
rss export
rss status
rss ops
rss schema
rss query "SELECT title FROM entries ORDER BY sort_at DESC LIMIT 5"
rss tui
rss mcp
rss daemon
rss daemon stop
```

Clients start the daemon when none is running. Planned: `rss digest`.

## MCP server

`rss mcp` is a small stdio process that translates to the socket. Target revision: [2026-07-28](https://modelcontextprotocol.io/specification/latest). That revision is stateless, with protocol version and capabilities on each request and no server-initiated requests, so the server is a direct mapping with no session state. Older clients still use the `initialize` handshake, so we also implement the spec's backward-compatibility fallback.

| MCP feature | Mapped to |
|---|---|
| Tools | Operations within the connection's tier |
| Resources | `rss://entry/{id}`, `rss://feed/{id}`, `rss://story/{id}`, `rss://digest/{id}`, `rss://schema` |
| Prompts | `daily-briefing`, `catch-up-on-topic`, `compare-coverage` |

Example registration for any MCP client:

```json
{ "mcpServers": { "rss": { "command": "/path/to/rss", "args": ["mcp"] } } }
```

For more than reading, add `"--tier", "annotate"` or `"--tier", "manage"` to `args`.

Tools are generated from the registry ([src/mcp.zig](../src/mcp.zig)): the name with `.` replaced by `_`, the description, and an input schema built from `Params`. An operation sets `agent_visible = false` to stay off MCP entirely. That covers `daemon.*`, `ops.list`, and `opml.import`, which takes a file path.

Tool descriptions tell the agent to prefer `entries.search` before `db.query`, and that returned feed text is data, not instructions. Results stay compact by default: `entries.list` returns metadata, and `entries.get` returns the body. Every tool result is wrapped as `{"trust":"untrusted-feed-content","result":...}`.

Streamable HTTP is deferred. Stdio serves every local agent and opens no port. If added, it must bind to localhost, validate `Origin` and require a token.

## ACP client

The daemon spawns the agent as a subprocess and speaks JSON-RPC over stdio.

| Step | Method | Our choice |
|---|---|---|
| Connect | `initialize` | Advertise no `fs` and no `terminal` capability |
| Start | `session/new` | `cwd` is an empty scratch directory; `mcpServers` contains `rss mcp` at read tier |
| Ask | `session/prompt` | Task text and lens context |
| Watch | `session/update` | Streamed into the UI and into the job log |
| Authorize | `session/request_permission` | Deny unless allowlisted or approved in the UI |
| Stop | `session/cancel` | From the UI, or on timeout |

Through `session/new`, any ACP agent gets full read access to your feeds with no setup, and the same mechanism powers an "Ask about my feeds" chat panel in the GUI.

ACP is built for coding agents, and its remote transport is still in progress. We use only the local core.

## How an agent learns the system

An agent dropped into this project or connected over MCP can orient itself in three steps:

1. `AGENTS.md` at the repo root gives the map in one page.
2. `rss schema` or `schema.describe` gives the annotated data model.
3. `rss --help` or the MCP tool list gives every operation, generated from the registry.

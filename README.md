# rss_

A local-first RSS reader with AI aggregation, built from scratch. Read in a GUI or TUI, connect any agent on your machine, and keep all of the data yourself.

Status: the daemon polls feeds in the background. Read them with the TUI or CLI, or through any MCP agent. No GUI or aggregator yet. `rss_` is a working name.

```bash
zig build -Drelease
./zig-out/bin/rss add https://ziglang.org/news/index.xml
./zig-out/bin/rss list
./zig-out/bin/rss show 1
./zig-out/bin/rss tui
```

![System overview](docs/diagrams/system.svg)

*One daemon owns the data; every interface is a thin client of the same API.*

## Documents

| Document | What it covers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Core design: processes, modules, ingest, content model, security, budgets |
| [schema/0001_init.sql](schema/0001_init.sql) | Data model |
| [docs/api.md](docs/api.md) | Operations, CLI, MCP, ACP |
| [docs/aggregator.md](docs/aggregator.md) | AI stages, lenses, runners |
| [docs/rss-primer.md](docs/rss-primer.md) | How RSS really works |
| [docs/decisions/0001-language.md](docs/decisions/0001-language.md) | Language choice |
| [docs/roadmap.md](docs/roadmap.md) | Milestones |
| [spikes/](spikes/README.md) | Throwaway experiments behind the language decision |
| [AGENTS.md](AGENTS.md) | Entry point for coding agents |

# rss_

A local-first RSS reader with AI aggregation, built from scratch. Read in a GUI or TUI, connect any agent on your machine, and keep all of the data yourself.

Status: the daemon polls feeds in the background, and fetches the full article when a feed gives only a summary. Read them with the macOS app, the TUI or CLI, or through any MCP agent. No aggregator yet. `rss_` is a working name.

Build and install the macOS app. It needs Zig 0.17.1 and Xcode's command line tools, and keeps your feeds and settings when replaced:

```bash
python3 tools/bundle_app.py --install
```

Or use the terminal:

```bash
zig build -Drelease
./zig-out/bin/rss add https://ziglang.org/news/index.xml
./zig-out/bin/rss list
./zig-out/bin/rss show 1
./zig-out/bin/rss tui
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/system-dark.svg">
  <img alt="System overview" src="docs/diagrams/system.svg">
</picture>

*One daemon owns the data; every interface is a thin client of the same API.*

## Documents

| Document | What it covers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Core design: processes, modules, ingest, content model, security, budgets |
| [schema/](schema/) | Data model |
| [docs/api.md](docs/api.md) | Operations, CLI, MCP, ACP |
| [docs/aggregator.md](docs/aggregator.md) | AI stages, lenses, runners |
| [docs/rss-primer.md](docs/rss-primer.md) | How RSS really works |
| [docs/decisions/0001-language.md](docs/decisions/0001-language.md) | Language choice |
| [docs/roadmap.md](docs/roadmap.md) | Milestones |
| [spikes/](spikes/README.md) | Throwaway experiments behind the language decision |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to work on this project |
| [AGENTS.md](AGENTS.md) | Entry point for coding agents |

## License

[MIT](LICENSE). Bundled fonts and SQLite keep their own terms: see [gui/Fonts](gui/Fonts) and [vendor/](vendor/).

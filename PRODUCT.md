# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Product Purpose

Fyke is a local-first RSS reader with one daemon owning SQLite and thin GUI, TUI, CLI, and MCP clients. AI aggregation is optional and planned. The project also teaches how its implementation works.

## Operating Context

People read feeds directly, search across them, and use agents through MCP. Planned saved views select topics; planned routines collect matches, notify, and apply article actions. Installed Codex is the first planned brief runner, with inspectable, editable instructions.

## Capabilities and Constraints

The core uses Zig; the existing macOS GUI uses SwiftUI. Only the daemon writes data, SQL stays in store, and article content renders as blocks. Model output belongs in artifacts with citations. Windows GUI delivery precedes Linux GUI delivery. Proposed toolkits and unimplemented capabilities are specified in [the implementation plan](docs/implementation-plan.md).

## Brand Commitments

Extend the existing Paper file and its exported token system. Preserve the reading-focused typography, themes, and bundled default reading font.

## Product Principles

- Keep local data usable without AI or an account.
- Expose capabilities through one operation registry.
- Distinguish internet source material from generated output.
- Make non-obvious behavior inspectable and explainable.

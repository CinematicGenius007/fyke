#!/usr/bin/env node
// Runs the official MCP client against `fyke mcp`, and reports which protocol era
// it used. Needs @modelcontextprotocol/client, which is not a project dependency:
//   npm i @modelcontextprotocol/client@2.4.0   (in any folder, then run from there)
// Usage: node sdk_mcp.mjs <path-to-fyke> [legacy|modern]
// The SDK uses `initialize` unless told otherwise, so `modern` pins 2026-07-28.
import { createRequire } from "node:module";
import { mkdtempSync, readFileSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const require = createRequire(process.cwd() + "/");
const load = (name) => import(pathToFileURL(require.resolve(name)).href);
const sdk = await load("@modelcontextprotocol/client");
const { Client, StdioClientTransport } = sdk.StdioClientTransport ? sdk : { ...sdk, ...(await load("@modelcontextprotocol/client/stdio")) };

const rss = resolve(process.argv[2]);
const home = mkdtempSync("/tmp/rss-k-");
const env = { ...process.env, FYKE_HOME: home };
writeFileSync(home + "/config.json", '{"auto_poll": false}');
// A shell wrapper records what the client really sends.
const wrapper = home + "/wrap.sh";
writeFileSync(wrapper, `#!/bin/sh\ntee -a ${home}/in.log | exec ${rss} mcp\n`);
chmodSync(wrapper, 0o755);

const era = process.argv[3] ?? "modern";
const options = era === "modern" ? { versionNegotiation: { mode: { pin: "2026-07-28" } } } : {};
const client = new Client({ name: "sdk-test", version: "1" }, options);
await client.connect(new StdioClientTransport({ command: wrapper, env }));
const assert = (name, ok) => { if (!ok) { console.log("FAIL", name); process.exit(1); } console.log("ok  ", name); };

assert("server identified", client.getServerVersion()?.name === "fyke");
const tools = (await client.listTools()).tools.map((t) => t.name);
assert("tools listed", tools.includes("entries_search") && !tools.includes("feeds_remove"));
const call = await client.callTool({ name: "stats_get", arguments: {} });
assert("tool called", !call.isError && call.content[0].text.includes("untrusted-feed-content"));
const bad = await client.callTool({ name: "entries_get", arguments: { id: 999 } });
assert("tool failure reported", bad.isError === true);
assert("resources listed", (await client.listResources()).resources.length === 1);
assert("templates listed", (await client.listResourceTemplates()).resourceTemplates.length === 2);
assert("schema read", (await client.readResource({ uri: "rss://schema" })).contents[0].text.includes("CREATE TABLE"));
assert("prompts listed", (await client.listPrompts()).prompts.length === 3);
assert("prompt read", (await client.getPrompt({ name: "catch-up-on-topic", arguments: { topic: "Zig" } })).messages.length === 1);
await client.close();

const sent = readFileSync(home + "/in.log", "utf8").trim().split("\n").map((l) => JSON.parse(l));
const versions = new Set(sent.map((m) => m.params?._meta?.["io.modelcontextprotocol/protocolVersion"]).filter(Boolean));
console.log("methods:", sent.map((m) => m.method).join(" "));
const used = sent.some((m) => m.method === "initialize") ? "legacy" : "modern";
console.log("era:", used, [...versions].join(" "));
assert("requested era was used", used === era);
execFileSync(rss, ["daemon", "stop"], { env });
rmSync(home, { recursive: true });

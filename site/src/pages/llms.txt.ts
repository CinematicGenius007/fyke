import type { APIRoute } from "astro";
import { getCollection } from "astro:content";
import { site, url } from "../site";
import { docSummary, docTitle } from "../docs-meta";

// A plain-text map of the site for language models: what the project is, what is
// true today, and where each document lives. llms-full.txt carries the documents.
export const GET: APIRoute = async ({ site: origin }) => {
  const abs = (p: string) => (origin ? new URL(url(p), origin).href : url(p));
  const docs = (await getCollection("docs")).sort((a, b) => a.id.localeCompare(b.id));
  const link = (path: string, name: string, note: string) => `- [${name}](${abs(path)}): ${note}`;
  const body = [
    `# ${site.name}`,
    "",
    `> ${site.name} is a local-first RSS reader for macOS, free and open source under the MIT licence. A background daemon fetches feeds into one SQLite database in a folder on the user's Mac, and the Mac app, a terminal reader, a command line program and an MCP server all read from it. There is no account, no telemetry and no server operated by the project.`,
    "",
    "## Status",
    "",
    "- Available now: feed fetching with full-article fallback, folders, full-text search, OPML import, themes, the SwiftUI Mac app (macOS 15 or later), the terminal reader, the command line program and an MCP server.",
    "- Install: build from source with Zig 0.17.1 and Xcode's command line tools. Signed prebuilt releases are planned and not available.",
    "- Planned, not built: an AI briefing in which every sentence cites the article it came from.",
    "",
    "## Pages",
    "",
    link("install/", "Install", "build the Mac app from source"),
    link("privacy/", "Privacy", "what the app stores, what it sends and what it never does"),
    link("roadmap/", "Roadmap", "milestones, built and planned"),
    "",
    "## Design documents",
    "",
    ...docs.filter((d) => d.id !== "roadmap").map((d) => link(`docs/${d.id}/`, docTitle(d.body ?? "", d.id), docSummary(d.body ?? "", ""))),
    "",
    "## Source",
    "",
    `- [Repository](${site.repo}): code, documents and issues`,
    "",
    "## Optional",
    "",
    link("llms-full.txt", "Full text", "every design document in one file"),
    "",
  ].join("\n");
  return new Response(body, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
};

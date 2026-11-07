import type { APIRoute } from "astro";
import { getCollection } from "astro:content";
import { site } from "../site";
import { docTitle } from "../docs-meta";

// Every design document as it is written in the repository, in one file.
export const GET: APIRoute = async () => {
  const docs = (await getCollection("docs")).sort((a, b) => a.id.localeCompare(b.id));
  const parts = docs.map((d) => `<!-- ${docTitle(d.body ?? "", d.id)}: docs/${d.id}.md -->\n\n${(d.body ?? "").trim()}\n`);
  return new Response([`# ${site.name}: design documents\n`, ...parts].join("\n---\n\n"), {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
};

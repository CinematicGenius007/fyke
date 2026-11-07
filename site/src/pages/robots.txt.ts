import type { APIRoute } from "astro";

// Everything is public and meant to be read, by people and by crawlers alike.
export const GET: APIRoute = ({ site }) => {
  const lines = ["User-agent: *", "Allow: /", ""];
  if (site) lines.push(`Sitemap: ${new URL(`${import.meta.env.BASE_URL.replace(/\/$/, "")}/sitemap-index.xml`, site).href}`, "");
  return new Response(lines.join("\n"), { headers: { "Content-Type": "text/plain; charset=utf-8" } });
};

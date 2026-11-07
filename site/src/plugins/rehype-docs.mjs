// Adapts the Markdown in docs/ to the site: links between documents become site
// links, links into the source tree become links to the repository, and the
// light and dark diagram pair becomes two images the page theme can choose from.
import path from "node:path";

const isElement = (n) => n && n.type === "element";

function walk(node, visit) {
  visit(node);
  for (const child of node.children ?? []) walk(child, visit);
}

export default function rehypeDocs({ base, repo }) {
  const root = base.replace(/\/$/, "");
  return (tree, file) => {
    // file.path is .../docs/<id>.md; the id decides what relative links mean.
    const rel = path.relative(path.resolve("../docs"), file.path ?? "");
    const dir = path.posix.dirname(rel.split(path.sep).join("/"));

    const resolve = (href) => {
      if (!href || /^([a-z]+:|#|\/)/i.test(href)) return href;
      const [target, hash] = href.split("#");
      const joined = path.posix.normalize(path.posix.join(dir, target));
      const suffix = hash ? `#${hash}` : "";
      if (joined.startsWith("..")) {
        const repoPath = joined.replace(/^(\.\.\/)+/, "");
        const kind = repoPath.endsWith("/") ? "tree" : "blob";
        return `${repo}/${kind}/main/${repoPath}${suffix}`;
      }
      if (joined === "roadmap.md") return `${root}/roadmap/${suffix}`;
      if (joined.endsWith(".md")) {
        return `${root}/docs/${joined.replace(/\.md$/, "")}/${suffix}`;
      }
      if (joined.endsWith(".mmd")) {
        return `${repo}/blob/main/docs/${joined}${suffix}`;
      }
      return `${root}/docs/${joined}${suffix}`;
    };

    walk(tree, (node) => {
      // Markdown keeps an HTML block as one raw node until a later stage parses it.
      if (node.type === "raw" && /<picture[\s>]/.test(node.value)) {
        const light = /<img[^>]*\ssrc="([^"]+)"/.exec(node.value)?.[1];
        const dark = /<source[^>]*\ssrcset="([^"]+)"/.exec(node.value)?.[1];
        const alt = /<img[^>]*\salt="([^"]*)"/.exec(node.value)?.[1] ?? "";
        if (light && dark) {
          node.value =
            `<span class="diagram"><img class="diagram-light" src="${resolve(light)}" alt="${alt}" loading="lazy">` +
            `<img class="diagram-dark" src="${resolve(dark)}" alt="" loading="lazy"></span>`;
        }
        return;
      }
      if (!isElement(node)) return;
      if (node.tagName === "a" && node.properties?.href) {
        node.properties.href = resolve(String(node.properties.href));
      }
      if (node.tagName === "picture") {
        const source = (node.children ?? []).find((c) => isElement(c) && c.tagName === "source");
        const img = (node.children ?? []).find((c) => isElement(c) && c.tagName === "img");
        if (!source || !img) return;
        const light = resolve(String(img.properties.src));
        const dark = resolve(String(source.properties.srcSet ?? source.properties.srcset));
        const make = (src, cls) => ({
          type: "element",
          tagName: "img",
          properties: { src, alt: img.properties.alt ?? "", className: [cls], loading: "lazy" },
          children: [],
        });
        node.tagName = "span";
        node.properties = { className: ["diagram"] };
        node.children = [make(light, "diagram-light"), make(dark, "diagram-dark")];
      }
    });
  };
}

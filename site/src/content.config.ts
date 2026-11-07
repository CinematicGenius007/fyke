import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";

// The documents in docs/ are the single source: the site renders them and does
// not keep a copy.
const docs = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "../docs" }),
});

export const collections = { docs };

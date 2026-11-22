// Subscription changes go through the same daemon operations as the Mac app.
import { transport } from "../transport";
import type { Items } from "./types";

export interface FeedCandidate {
  url: string;
  title?: string | null;
  latest: string[];
}

export async function previewFeeds(url: string, localFeeds: boolean) {
  const result = await transport().call<Items<FeedCandidate>>(
    "feeds.preview", { url, allow_private_network: localFeeds }, { slow: true },
  );
  return result.items;
}

export async function subscribeFeeds(picked: FeedCandidate[], name: string, folder: number | null, localFeeds: boolean) {
  for (const candidate of picked) {
    const title = picked.length === 1 && name && name !== candidate.title ? name : undefined;
    const { id } = await transport().call<{ id: number }>(
      "feeds.add", { url: candidate.url, title, allow_private_network: localFeeds }, { slow: true },
    );
    if (folder !== null) await transport().call("feeds.update", { id, folder_id: folder });
  }
}

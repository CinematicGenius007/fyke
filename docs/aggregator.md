# AI aggregator

The aggregation logic is deliberately undecided, so the design treats it as **configuration you can experiment with**, not code you commit to. This document proposes a default to start from.

The aggregator is optional. It only reads entries and writes artifacts, so turning it off changes nothing else.

## What it should do

Turn "2,000 unread items" into "the 12 things that happened and why they matter to you", with every statement traceable to its source.

## Stages

![Aggregation stages](diagrams/aggregate.svg)

*Each stage narrows the data, so expensive model calls only touch the small set that survives.* ([source](diagrams/aggregate.mmd))

| Stage | Input to output | Uses a model? | Notes |
|---|---|---|---|
| **Dedupe** | Entries to unique entries | No | Same `canonical_url`, or `simhash` within 3 bits. Part of ingest, always on |
| **Enrich** | Entry to summary, topics, embedding | Small or local | Once per entry, cached, skipped for short entries |
| **Cluster** | Entries to stories | No | See below |
| **Rank** | Stories to ordered stories | No | See below |
| **Synthesize** | Top stories to digest | Large | One call per digest, so cost stays bounded |

Cost grows with the number of *new* entries at the cheap stage only. The expensive stage runs a fixed number of times per day.

### Clustering

Incremental, so a new entry never reclusters history:

1. Compare the new entry's embedding with the centroids of stories active in the last 72 hours.
2. Above a similarity threshold, join that story. Otherwise start a new one.
3. Shared named entities lower the threshold; a large time gap raises it.

The first version can skip embeddings and use FTS5 term overlap, proving the UI before any model is involved.

### Ranking

A transparent formula rather than a learned black box:

```text
score = w1 * interest      similarity to interests.md and to starred entries
      + w2 * corroboration number of independent feeds in the story
      + w3 * novelty       distance from what you already read this week
      + w4 * recency       exponential decay
      - w5 * fatigue       similar stories you hid or skipped
```

The UI shows why a story ranked where it did. `interests.md` is plain text you edit, and the weights live in the lens.

### Synthesis and citations

The model receives top stories as Markdown with entry ids and returns structured output. Each claim must cite entry ids. Validation before storing:

- Output parses against the expected shape.
- Every cited id was in the input. Fabricated ids reject the artifact.
- At least one citation exists.

A failed validation retries once and then marks the job failed. It never stores unsourced output.

## Lenses

A lens is one named aggregation. Trying a new idea means adding a lens, not writing code.

```json
{
  "name": "Morning brief",
  "select": { "folders": ["Tech", "AI"], "since_hours": 24, "exclude_read": true },
  "stages": {
    "enrich": { "runner": "local-small" },
    "cluster": { "method": "embedding", "threshold": 0.78, "window_hours": 72 },
    "rank": { "weights": { "interest": 3, "corroboration": 2, "novelty": 2, "recency": 1, "fatigue": 2 } },
    "synthesize": { "runner": "big-model", "top_stories": 12, "prompt": "prompts/brief.md" }
  },
  "schedule": "0 7 * * *",
  "tools": "none"
}
```

Ideas that fit the same shape:

| Lens | Differs by |
|---|---|
| Morning brief | Default above |
| Deep topic watch | Narrow selection, long window, more detail |
| Disagreement finder | Prompt asks where sources conflict within a story |
| Weekly catch-up | 7 days, heavier novelty weight |
| Quiet feeds | Boosts low-volume feeds that big ones drown out |

## Runners

A runner is how a stage reaches a model or agent. All three take the same task and return the same result, so stages do not care which is used.

```json
{ "task": "synthesize", "input": { "stories": [] }, "output_schema": {}, "limits": { "max_output_tokens": 4000, "timeout_ms": 120000 } }
```

```json
{ "output": {}, "model": "<model-id>", "usage": { "input_tokens": 0, "output_tokens": 0 } }
```

| Kind | Reaches | Config |
|---|---|---|
| `http` | Hosted APIs and local servers such as Ollama | URL, model, API style, key reference |
| `exec` | Any program: JSON on stdin, JSON on stdout | Command, args, env |
| `acp` | Any ACP agent | Command, args. See [api.md](api.md#acp-client) |

**This is how "different agent SDKs" works.** Agent SDKs are mostly Python and TypeScript libraries, and linking them into the core would defeat its purpose. Instead, each SDK is a short `exec` script in `runners/`. The core stays small and from scratch, and the SDK's language stops mattering.

```json
{ "name": "sdk-experiment", "kind": "exec", "config": { "command": "python3", "args": ["runners/my_agent.py"] } }
```

### Comparing agents

`artifacts.producer` and `model` record who made each output. Running one lens on two runners gives two artifacts over the same input, which the GUI and TUI show side by side. That doubles as an evaluation tool: you find out which setup you actually prefer by reading the results.

## Jobs

Work runs through the `jobs` table: durable, resumable after a crash, retried with backoff. Limits per runner cover concurrency, requests per minute and a daily token budget. Token usage is stored per job and shown in the UI, so cost is never a surprise.

## In the UI

- **Briefing:** latest digest per lens, with claims linking to sources.
- **Stories:** clusters instead of a flat timeline, with a coverage count per story.
- **Entry sidebar:** summary, labeled with who generated it.
- **Jobs:** queue status, logs, streamed ACP progress, cost.
- **Compare:** two artifacts side by side.

AI text is always visually labeled, in both GUI and TUI.

## Open questions

Answer these by using it, not in advance:

- Is the unit of reading a story or a digest?
- Should summaries be precomputed for everything, or on open?
- Does the clustering threshold need to vary by topic?
- Which feedback signals are honest? Dwell time may be noise.
- Do we need full-text fetching for summary-only feeds? It improves everything downstream but adds a scraper.

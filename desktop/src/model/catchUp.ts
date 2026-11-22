// Catch-up keeps its queue in the reader and the marks in the daemon.
import { createSignal } from "solid-js";
import { CatchUpSession, type Decision } from "../logic/CatchUpSession";
import { transport } from "../transport";
import type { Library } from "./library";
import type { EntryPage, EntrySummary, Previous } from "./types";

export function createCatchUp(
  title: string,
  params: Record<string, unknown>,
  library: Library,
  words: (error: unknown) => string,
  open: (id: number) => void,
) {
  let session = new CatchUpSession<number>([]);
  const rows = new Map<number, EntrySummary>();
  const previous = new Map<number, Previous>();
  const [index, setIndex] = createSignal(0);
  const [loaded, setLoaded] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  const [problem, setProblem] = createSignal<string | null>(null);

  return {
    title,
    loaded,
    busy,
    problem,
    index,
    length: () => loaded() ? session.queue.length : 0,
    current: () => loaded() ? rows.get(session.queue[index()]) : undefined,
    count: (decision: Decision) => index() === 0 ? 0 : session.count(decision),
    async load() {
      try {
        const page = await transport().call<EntryPage>("entries.list", { ...params, limit: 500 });
        for (const row of page.items) {
          if (!row.read) rows.set(row.id, row);
        }
        session = new CatchUpSession([...rows.keys()]);
      } catch (error) {
        setProblem(words(error));
      } finally {
        setLoaded(true);
      }
    },
    async decide(decision: Decision) {
      const id = session.current;
      if (id === undefined || busy() || problem()) return;
      setBusy(true);
      try {
        const before = await library.mark([id], decision === "later" ? { later: true } : { read: true });
        const marks = before.get(id);
        if (!marks) throw new Error("Fyke did not return the previous article marks.");
        previous.set(id, marks);
        session.decide(decision);
        setIndex(session.index);
        if (decision === "read") open(id);
      } catch (error) {
        setProblem(words(error));
      } finally {
        setBusy(false);
      }
    },
    async undo() {
      const last = session.history.at(-1);
      if (!last || busy()) return;
      const before = previous.get(last.id);
      if (!before) return;
      setBusy(true);
      try {
        await library.mark([last.id], last.decision === "later" ? { later: before.later } : { read: before.read });
        previous.delete(last.id);
        session.undo();
        setIndex(session.index);
        setProblem(null);
      } catch (error) {
        setProblem(words(error));
      } finally {
        setBusy(false);
      }
    },
  };
}

export type CatchUpModel = ReturnType<typeof createCatchUp>;

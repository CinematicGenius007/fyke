// Walks a list of articles one at a time. Each decision is remembered, so the last one
// can be taken back and the article shown again.
// Mirrors `CatchUpSession` in gui/Sources/ReaderLogic/Logic.swift.

export type Decision = "skip" | "later" | "read";

export class CatchUpSession<ID> {
  private position = 0;
  private decided: { id: ID; decision: Decision }[] = [];

  constructor(readonly queue: readonly ID[]) {}

  get index(): number {
    return this.position;
  }

  get history(): readonly { id: ID; decision: Decision }[] {
    return this.decided;
  }

  get current(): ID | undefined {
    return this.position < this.queue.length ? this.queue[this.position] : undefined;
  }

  get isDone(): boolean {
    return this.position >= this.queue.length;
  }

  get progress(): number {
    return this.queue.length === 0 ? 1 : this.position / this.queue.length;
  }

  count(decision: Decision): number {
    return this.decided.filter((row) => row.decision === decision).length;
  }

  decide(decision: Decision): ID | undefined {
    const id = this.current;
    if (id === undefined) return undefined;
    this.decided.push({ id, decision });
    this.position += 1;
    return id;
  }

  /** Puts the last decided article back in front. */
  undo(): { id: ID; decision: Decision } | undefined {
    const last = this.decided.pop();
    if (!last) return undefined;
    this.position = Math.max(this.position - 1, 0);
    return last;
  }
}

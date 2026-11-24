// Changes that can be taken back, newest last. Bulk actions push here instead of asking
// first, and Ctrl+Z pops. Mirrors `UndoStack` in gui/Sources/ReaderLogic/Logic.swift.

export class UndoStack<Item> {
  private list: Item[] = [];

  constructor(readonly limit = 100) {}

  get items(): readonly Item[] {
    return this.list;
  }

  push(item: Item): void {
    this.list.push(item);
    if (this.list.length > this.limit) this.list.splice(0, this.list.length - this.limit);
  }

  pop(): Item | undefined {
    return this.list.pop();
  }

  get last(): Item | undefined {
    return this.list[this.list.length - 1];
  }

  get isEmpty(): boolean {
    return this.list.length === 0;
  }

  get count(): number {
    return this.list.length;
  }
}

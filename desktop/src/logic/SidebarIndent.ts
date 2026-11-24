// Indent is `10 + 22 × depth`. 22 is the icon (14) and the gap (8), so a row one level
// down starts where its parent's text starts. It is computed here, once, and every row
// at one depth uses the same value, so siblings always line up.
// Mirrors gui/Sources/ReaderLogic/Logic.swift.

export const SidebarIndent = {
  edge: 10,
  icon: 14,
  gap: 8,
  get step(): number {
    return this.icon + this.gap;
  },

  leading(depth: number): number {
    return this.edge + this.step * Math.max(depth, 0);
  },

  /**
   * Folders draw a chevron in the icon column, feeds draw none, so a feed's name starts
   * where its depth's icon would. Inside a folder a feed is a child: its name starts one
   * step inside the folder's name, level with a sibling folder's name. A feed at the top
   * level sits at depth 1, so its name lines up with All, Starred and top-level folders.
   */
  feedDepth(folderDepth: number | null | undefined): number {
    return folderDepth == null ? 1 : folderDepth + 2;
  },

  /** Where the text of a row starts. */
  textStart(depth: number, hasIcon: boolean): number {
    return this.leading(depth) + (hasIcon ? this.step : 0);
  },
};

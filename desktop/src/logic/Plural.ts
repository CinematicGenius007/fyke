// Counting words. Mirrors `Plural` in gui/Sources/ReaderLogic/Logic.swift, which groups
// digits in the person's locale.

const grouped = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 });

export const Plural = {
  count(number: number, noun: string, plural?: string): string {
    return `${grouped.format(number)} ${number === 1 ? noun : (plural ?? noun + "s")}`;
  },
};

// The name a kept search starts with. The person can change it straight away.
// Mirrors `ViewName` in gui/Sources/ReaderLogic/Rule.swift.
import { Rule } from "./Rule";
import { RuleSentence } from "./RuleSentence";

export const ViewName = {
  suggest(input: Rule): string {
    const rule = Rule.normalized(input);
    if (rule.words == null) return rule.state == null ? "New view" : RuleSentence.stateWord(rule.state);
    const joined = rule.words.split(" ").join(rule.any_words === true ? " or " : " ");
    const [first = "", ...rest] = Array.from(joined);
    return first.toUpperCase() + rest.join("");
  },

  /** A name that no other view has, by adding a number. */
  unique(name: string, taken: ReadonlySet<string>): string {
    if (!taken.has(name)) return name;
    for (let n = 2; n <= 999; n++) {
      const candidate = `${name} ${n}`;
      if (!taken.has(candidate)) return candidate;
    }
    return name;
  },
};

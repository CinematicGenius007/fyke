// The ReaderLogic tests from gui/Tests/ReaderLogicTests/LogicTests.swift, case for case,
// so both apps decide the same things the same way.
import { describe, expect, test } from "bun:test";
import { CatchUpSession } from "../../src/logic/CatchUpSession";
import { DryRunWords } from "../../src/logic/DryRunWords";
import { Fuzzy } from "../../src/logic/Fuzzy";
import { Rule } from "../../src/logic/Rule";
import { RuleSentence } from "../../src/logic/RuleSentence";
import { Schedule } from "../../src/logic/Schedule";
import { SidebarIndent } from "../../src/logic/SidebarIndent";
import { SourcesNote } from "../../src/logic/SourcesNote";
import { UndoStack } from "../../src/logic/UndoStack";
import { ViewName } from "../../src/logic/ViewName";

describe("IndentTests", () => {
  test("indent is ten plus twenty-two per level", () => {
    expect(SidebarIndent.leading(0)).toBe(10);
    expect(SidebarIndent.leading(1)).toBe(32);
    expect(SidebarIndent.leading(3)).toBe(76);
  });

  test("a child starts one step inside its parent", () => {
    for (let depth = 0; depth < 5; depth++) {
      const folderText = SidebarIndent.textStart(depth, true);
      const feedText = SidebarIndent.textStart(SidebarIndent.feedDepth(depth), false);
      const childFolderChevron = SidebarIndent.leading(depth + 1);
      const childFolderText = SidebarIndent.textStart(depth + 1, true);
      expect(feedText).toBe(folderText + SidebarIndent.step);
      expect(childFolderChevron).toBe(folderText);
      expect(childFolderText).toBe(feedText);
    }
  });

  test("siblings share one indent", () => {
    const parent = 1;
    const feed = SidebarIndent.textStart(SidebarIndent.feedDepth(parent), false);
    const folder = SidebarIndent.textStart(parent + 1, true);
    expect(feed).toBe(folder);
  });

  test("top-level feeds line up with destination names", () => {
    expect(SidebarIndent.textStart(SidebarIndent.feedDepth(null), false)).toBe(SidebarIndent.textStart(0, true));
  });
});

describe("RuleTests", () => {
  const feeds = new Map([
    [3, "Database Notes"],
    [7, "Systems Journal"],
  ]);
  const folders = new Map([[2, "Engineering"]]);
  const parts = (rule: Rule) =>
    RuleSentence.parts(
      rule,
      (id) => feeds.get(id),
      (id) => folders.get(id),
    );

  test("an empty rule reads as articles from all feeds", () => {
    expect(RuleSentence.text(parts({}))).toBe("Articles from all feeds");
    expect(RuleSentence.text(parts({ state: "any", words: "needle" }))).toBe("Articles from all feeds about needle");
    expect(RuleSentence.text(parts({ folders: [2], state: "unread", words: "storage" }))).toBe("Unread from Engineering about storage");
  });

  test("every clause becomes words", () => {
    const rule: Rule = { folders: [2], state: "unread", words: "storage query", any_words: true, exclude_path_prefix: ["/jobs/"], within_days: 7 };
    expect(RuleSentence.text(parts(rule))).toBe("Unread from Engineering about storage or query skipping /jobs/ from the last week");
    expect(parts(rule)[0]).toEqual({ kind: "chip", clause: "state", text: "Unread" });
  });

  test("deleted sources are named", () => {
    expect(RuleSentence.text(parts({ feeds: [99] }))).toBe("Articles from Deleted source");
  });

  test("many sources are counted", () => {
    expect(RuleSentence.text(parts({ feeds: [3, 7], folders: [2] })).startsWith("Articles from Engineering and 2 more")).toBe(true);
  });

  test("edits round-trip through the sentence", () => {
    let rule = Rule.fromSearch("  storage   engine ", true);
    expect(rule).toEqual({ state: "unread", words: "storage engine" });
    rule = Rule.setWords(rule, "storage engine", true);
    expect(parts(rule)).toContainEqual({ kind: "chip", clause: "words", text: "storage or engine", value: "storage engine" });
    rule = Rule.setHost(rule, "https://Blog.Example.com/posts", true);
    expect(rule.host).toBe("blog.example.com");
    expect(rule.subdomains).toBe(true);
    rule = Rule.addExclude(rule, "jobs");
    rule = Rule.addExclude(rule, "/jobs");
    expect(rule.exclude_path_prefix).toEqual(["/jobs"]);
    rule = Rule.removeExclude(rule, "/jobs");
    expect(rule.exclude_path_prefix).toBeUndefined();
    rule = Rule.setState(rule, "any");
    expect(rule.state).toBeUndefined();
    rule = Rule.clear(rule, "words");
    expect(rule.words).toBeUndefined();
    expect(rule.any_words).toBeUndefined();
    rule = Rule.setWords(rule, "   ", false);
    expect(rule.words).toBeUndefined();
  });

  test("rules encode in the daemon's spelling", () => {
    const rule: Rule = { state: "unread", any_words: true, path_prefix: "/blog", within_days: 7 };
    const sorted = Object.fromEntries(Object.entries(rule).sort(([a], [b]) => a.localeCompare(b)));
    expect(JSON.stringify(sorted)).toBe('{"any_words":true,"path_prefix":"/blog","state":"unread","within_days":7}');
  });

  test("normalized ignores defaults the daemon fills in", () => {
    const full: Rule = JSON.parse(
      '{"feeds":[],"folders":[],"state":"any","words":"x","any_words":false,"host":null,"subdomains":false,"path_prefix":null,"exclude_path_prefix":[],"within_days":null}',
    );
    expect(Rule.normalized(full)).toEqual({ words: "x" });
    expect(Rule.same(full, { words: "x" })).toBe(true);
  });

  test("suggested names are unique", () => {
    expect(ViewName.suggest({ words: "storage query", any_words: true })).toBe("Storage or query");
    expect(ViewName.suggest({})).toBe("New view");
    expect(ViewName.suggest({ state: "unread" })).toBe("Unread");
    expect(ViewName.unique("Storage", new Set(["Storage", "Storage 2"]))).toBe("Storage 3");
  });

  test("within is clamped and missing clauses come in sentence order", () => {
    expect(Rule.setWithin({}, 0).within_days).toBe(1);
    expect(Rule.setWithin({}, 99999).within_days).toBe(3650);
    expect(Rule.missing({ words: "x", within_days: 7 })).toEqual(["host", "path", "exclude"]);
  });
});

describe("UndoTests", () => {
  test("pops newest first and keeps a limit", () => {
    const stack = new UndoStack<number>(3);
    for (let n = 1; n <= 5; n++) stack.push(n);
    expect([...stack.items]).toEqual([3, 4, 5]);
    expect(stack.pop()).toBe(5);
    expect(stack.pop()).toBe(4);
    expect(stack.last).toBe(3);
    expect(stack.pop()).toBe(3);
    expect(stack.pop()).toBeUndefined();
  });
});

describe("CatchUpTests", () => {
  test("decisions advance and undo goes back", () => {
    const session = new CatchUpSession([10, 20, 30]);
    expect(session.current).toBe(10);
    session.decide("skip");
    session.decide("later");
    expect(session.current).toBe(30);
    expect(session.count("skip")).toBe(1);
    expect(session.count("later")).toBe(1);
    const undone = session.undo();
    expect(undone).toEqual({ id: 20, decision: "later" });
    expect(session.current).toBe(20);
    session.decide("read");
    session.decide("read");
    expect(session.isDone).toBe(true);
    expect(session.progress).toBe(1);
    expect(session.decide("skip")).toBeUndefined();
  });
});

describe("FuzzyTests", () => {
  test("letters match in order", () => {
    expect(Fuzzy.match("dbn", "Database Notes")).not.toBeNull();
    expect(Fuzzy.match("ndb", "Database Notes")).toBeNull();
    expect(Fuzzy.match("", "Anything")?.positions).toEqual([]);
  });

  test("word starts and runs rank first", () => {
    const ranked = Fuzzy.rank("data", ["Update all feeds", "Database Notes", "Databases"], (s) => s).map((r) => r.item);
    expect(ranked[0]).toBe("Databases");
    expect(ranked[ranked.length - 1]).toBe("Update all feeds");
  });

  test("positions point at matched letters", () => {
    expect(Fuzzy.match("dn", "Database Notes")?.positions).toEqual([0, 9]);
  });
});

describe("ScheduleTests", () => {
  test("when reads as words", () => {
    expect(Schedule.repeatWords({ kind: "weekdays", time: "07:30" })).toBe("Every weekday");
    expect(Schedule.summary({ kind: "weekdays", time: "07:30" })).toBe("Weekdays 07:30");
    expect(Schedule.repeatWords({ kind: "weekly", time: "17:00", days: [5] })).toBe("Every Friday");
    expect(Schedule.repeatWords({ kind: "weekly", days: [6, 1] })).toBe("On Mon, Sat");
    expect(Schedule.halfHours.length).toBe(48);
    expect(Schedule.halfHours[15]).toBe("07:30");
  });

  test("dry run says what would have happened", () => {
    expect(DryRunWords.summary([10, 4, 12, 7, 5, 0, 0])).toBe("Would have caught 38 articles over 5 days, about 8 each.");
    expect(DryRunWords.summary([0, 0])).toBe("Nothing would have matched last week.");
    expect(DryRunWords.bars([0, 1, 100])).toEqual([0, 0.12, 1]);
  });
});

describe("SourcesNoteTests", () => {
  test("read but not cited says more once", () => {
    expect(SourcesNote.text(0, 4, 2)).toBe("2 more read but not cited");
    expect(SourcesNote.text(0, 3, 2)).toBe("1 more read but not cited");
  });

  test("what did not fit comes first", () => {
    expect(SourcesNote.text(409, 16, 3)).toBe("409 more articles matched but did not fit, so the writer did not read them.");
    expect(SourcesNote.text(1, 2, 2)).toBe("1 more article matched but did not fit, so the writer did not read them.");
  });

  test("nothing when every read article is cited", () => {
    expect(SourcesNote.text(0, 2, 2)).toBeNull();
    expect(SourcesNote.text(0, 0, 2)).toBeNull();
  });
});

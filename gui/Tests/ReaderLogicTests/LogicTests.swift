import Foundation
import Testing

@testable import ReaderLogic

@Suite struct IndentTests {
    @Test func indentIsTenPlusTwentyTwoPerLevel() {
        #expect(SidebarIndent.leading(depth: 0) == 10)
        #expect(SidebarIndent.leading(depth: 1) == 32)
        #expect(SidebarIndent.leading(depth: 3) == 76)
    }

    @Test func childTextLinesUpWithParentText() {
        for depth in 0..<5 {
            let folderText = SidebarIndent.textStart(depth: depth, hasIcon: true)
            let feedText = SidebarIndent.textStart(depth: SidebarIndent.feedDepth(folderDepth: depth), hasIcon: false)
            let childFolderChevron = SidebarIndent.leading(depth: depth + 1)
            #expect(feedText == folderText)
            #expect(childFolderChevron == folderText)
        }
    }

    @Test func siblingsShareOneIndent() {
        // A feed and a folder side by side in one folder: the feed's name and the
        // folder's chevron start at the same x.
        let parent = 1
        let feed = SidebarIndent.textStart(depth: SidebarIndent.feedDepth(folderDepth: parent), hasIcon: false)
        let folder = SidebarIndent.leading(depth: parent + 1)
        #expect(feed == folder)
    }

    @Test func topLevelFeedsLineUpWithDestinationNames() {
        #expect(SidebarIndent.textStart(depth: SidebarIndent.feedDepth(folderDepth: nil), hasIcon: false) == SidebarIndent.textStart(depth: 0, hasIcon: true))
    }
}

@Suite struct RuleTests {
    let feeds: [Int64: String] = [3: "Database Notes", 7: "Systems Journal"]
    let folders: [Int64: String] = [2: "Engineering"]

    func parts(_ rule: Rule) -> [SentencePart] {
        RuleSentence.parts(rule, feedName: { feeds[$0] }, folderName: { folders[$0] })
    }

    @Test func emptyRuleReadsAsAllFromAllFeeds() {
        #expect(RuleSentence.text(parts(Rule())) == "All from all feeds")
    }

    @Test func everyClauseBecomesWords() {
        let rule = Rule(folders: [2], state: .unread, words: "storage query", anyWords: true, excludePathPrefix: ["/jobs/"], withinDays: 7)
        #expect(RuleSentence.text(parts(rule)) == "Unread from Engineering about storage or query skipping /jobs/ from the last week")
        #expect(parts(rule).first == .chip(.state, "Unread"))
    }

    @Test func deletedSourcesAreNamed() {
        #expect(RuleSentence.text(parts(Rule(feeds: [99]))) == "All from Deleted source")
    }

    @Test func manySourcesAreCounted() {
        #expect(RuleSentence.text(parts(Rule(feeds: [3, 7], folders: [2]))).hasPrefix("All from Engineering and 2 more"))
    }

    @Test func editsRoundTripThroughTheSentence() {
        var rule = Rule.fromSearch("  storage   engine ", unreadOnly: true)
        #expect(rule == Rule(state: .unread, words: "storage engine"))
        rule.setWords("storage engine", any: true)
        #expect(parts(rule).contains(.chip(.words, "storage or engine", value: "storage engine")))
        rule.setHost("https://Blog.Example.com/posts", subdomains: true)
        #expect(rule.host == "blog.example.com" && rule.subdomains == true)
        rule.addExclude("jobs")
        rule.addExclude("/jobs")
        #expect(rule.excludePathPrefix == ["/jobs"])
        rule.removeExclude("/jobs")
        #expect(rule.excludePathPrefix == nil)
        rule.setState(.any)
        #expect(rule.state == nil)
        rule.clear(.words)
        #expect(rule.words == nil && rule.anyWords == nil)
        rule.setWords("   ", any: false)
        #expect(rule.words == nil)
    }

    @Test func rulesEncodeInTheDaemonsSpelling() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(Rule(state: .unread, anyWords: true, pathPrefix: "/blog", withinDays: 7)), as: UTF8.self)
        #expect(text == #"{"any_words":true,"path_prefix":"\/blog","state":"unread","within_days":7}"#)
    }

    @Test func normalizedIgnoresDefaultsTheDaemonFillsIn() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let full = #"{"feeds":[],"folders":[],"state":"any","words":"x","any_words":false,"host":null,"subdomains":false,"path_prefix":null,"exclude_path_prefix":[],"within_days":null}"#
        let rule = try decoder.decode(Rule.self, from: Data(full.utf8))
        #expect(rule.normalized == Rule(words: "x"))
    }

    @Test func suggestedNamesAreUnique() {
        #expect(ViewName.suggest(for: Rule(words: "storage query", anyWords: true)) == "Storage or query")
        #expect(ViewName.unique("Storage", taken: ["Storage", "Storage 2"]) == "Storage 3")
    }
}

@Suite struct UndoTests {
    @Test func popsNewestFirstAndKeepsALimit() {
        var stack = UndoStack<Int>(limit: 3)
        for n in 1...5 { stack.push(n) }
        #expect(stack.items == [3, 4, 5])
        #expect(stack.pop() == 5)
        #expect(stack.pop() == 4)
        #expect(stack.last == 3)
        #expect(stack.pop() == 3)
        #expect(stack.pop() == nil)
    }
}

@Suite struct CatchUpTests {
    @Test func decisionsAdvanceAndUndoGoesBack() {
        var session = CatchUpSession([10, 20, 30])
        #expect(session.current == 10)
        session.decide(.skip)
        session.decide(.later)
        #expect(session.current == 30)
        #expect(session.count(.skip) == 1 && session.count(.later) == 1)
        let undone = session.undo()
        #expect(undone?.id == 20 && undone?.decision == .later)
        #expect(session.current == 20)
        session.decide(.read)
        session.decide(.read)
        #expect(session.isDone && session.progress == 1)
        #expect(session.decide(.skip) == nil)
    }
}

@Suite struct FuzzyTests {
    @Test func lettersMatchInOrder() {
        #expect(Fuzzy.match("dbn", in: "Database Notes") != nil)
        #expect(Fuzzy.match("ndb", in: "Database Notes") == nil)
        #expect(Fuzzy.match("", in: "Anything")?.positions == [])
    }

    @Test func wordStartsAndRunsRankFirst() {
        let ranked = Fuzzy.rank("data", ["Update all feeds", "Database Notes", "Databases"]) { $0 }.map(\.item)
        #expect(ranked.first == "Databases")
        #expect(ranked.last == "Update all feeds")
    }

    @Test func positionsPointAtMatchedLetters() {
        #expect(Fuzzy.match("dn", in: "Database Notes")?.positions == [0, 9])
    }
}

@Suite struct ScheduleTests {
    @Test func whenReadsAsWords() {
        #expect(Schedule(kind: .weekdays, time: "07:30").repeatWords == "Every weekday")
        #expect(Schedule(kind: .weekdays, time: "07:30").summary == "Weekdays 07:30")
        #expect(Schedule(kind: .weekly, time: "17:00", days: [5]).repeatWords == "Every Friday")
        #expect(Schedule(kind: .weekly, days: [6, 1]).repeatWords == "On Mon, Sat")
        #expect(Schedule.halfHours.count == 48 && Schedule.halfHours[15] == "07:30")
    }

    @Test func dryRunSaysWhatWouldHaveHappened() {
        #expect(DryRunWords.summary(counts: [10, 4, 12, 7, 5, 0, 0]) == "Would have caught 38 articles over 5 days, about 8 each.")
        #expect(DryRunWords.summary(counts: [0, 0]) == "Nothing would have matched last week.")
        #expect(DryRunWords.bars([0, 1, 100]) == [0, 0.12, 1])
    }
}

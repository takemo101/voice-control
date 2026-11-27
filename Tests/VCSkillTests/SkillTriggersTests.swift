import Foundation
import Testing
import TestSupport
@testable import VCSkill
import VCCore
import VCDecision

/// スキルの言い方の規則（フロントマター `triggers`）：読み込みの検査・照合・スキルの解決への効き方。コアには、特定のスキルの規則を、持たない。
@Suite struct SkillTriggersTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func skill(_ name: String, _ description: String, triggers: [String] = [], confirm: Bool = false) -> Skill {
        var skill = Skill(name: name, description: description, allowedCommands: ["echo"], confirm: confirm, body: "x", file: URL(string: "builtin:\(name)")!, scope: .global)
        skill.triggers = triggers
        return skill
    }

    private func parsed(_ front: String) -> Result<Skill, SkillStore.ParseError> {
        SkillStore.parse("---\nname: demo\ndescription: d\nallowed-commands:\n  - echo\n\(front)---\nbody\n", directoryName: "demo", file: URL(fileURLWithPath: "/tmp/demo/SKILL.md"))
    }

    // MARK: 読み込み

    @Test func triggersAreReadAsAListAndKeepTheirRegexCharacters() throws {
        let skill = try parsed("triggers:\n  - ^(?=.*[0-9]{1,2}時)(?=.*予約)\n  - 正午|:[0-9]{2}\n").get()
        #expect(skill.triggers == ["^(?=.*[0-9]{1,2}時)(?=.*予約)", "正午|:[0-9]{2}"])
        #expect(try parsed("").get().triggers.isEmpty)   // 書かなければ、なし
    }

    @Test func brokenOrTooManyOrTooLongTriggersFailTheLoadWithAReason() {
        for front in ["triggers:\n  - (未完\n", "triggers:\n  - ''\n", "triggers:\n  - \(String(repeating: "a", count: SkillTriggers.maxLength + 1))\n",
                      "triggers:\n" + (0...SkillTriggers.maxCount).map { "  - 規則\($0)\n" }.joined()] {
            if case .success = parsed(front) { Issue.record("読み込めてしまった: \(front.prefix(40))") }
        }
    }

    // MARK: 照合

    @Test func matchingReadsFullWidthDigitsAndIgnoresSpacesAndRequiresBothPartsOfALookaheadPair() {
        let patterns = ["^(?=.*[0-9]{1,2}時)(?=.*予約)"]
        #expect(SkillTriggers.matches("１０時に　音楽をかける 予約して", patterns: patterns))
        #expect(!SkillTriggers.matches("10時に音楽をかけて", patterns: patterns) && !SkillTriggers.matches("予約を確認して", patterns: patterns))
        #expect(!SkillTriggers.matches("10時に予約", patterns: []))
    }

    // MARK: 解決

    private func resolved(_ request: String, _ skills: [Skill]) throws -> SkillResolver.Resolution? {
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: "Spotify の操作"), skills: skills, gate: Gate())
        guard case let .resolved(r) = try resolver.resolve(request) else { return nil }
        return r
    }

    @Test func aSingleTriggeredSkillIsChosenEvenWhenTheRouterPrefersAnotherAndOnlyWhenItIsPresent() throws {
        let spotify = skill("spotify", "Spotify の操作"), scheduler = skill("scheduler", "予約", triggers: ["予約"])
        #expect(try resolved("10時に音楽をかける予約をして", [spotify, scheduler])?.skill.name == "scheduler")
        #expect(try resolved("10時に音楽をかける予約をして", [spotify])?.skill.name == "spotify")   // 入っていない・無効なら、いままでどおり
        #expect(try resolved("音楽をかけて", [spotify, scheduler])?.skill.name == "spotify")   // 当たらなければ、Tiny-Jev の選択
    }

    @Test func severalTriggeredSkillsAreNarrowedToThoseAndTheRouterPicksAmongThem() throws {
        let spotify = skill("spotify", "Spotify の操作", triggers: ["予約"]), scheduler = skill("scheduler", "予約", triggers: ["予約"]), other = skill("other", "別")
        let r = try resolved("予約して", [spotify, scheduler, other])
        #expect(r?.skill.name == "spotify")   // 代役の Tiny-Jev は、Spotify を選ぶ：候補は、当たった 2 つだけ
    }

    @Test func aTriggeredSkillThatNeedsConfirmationStillAsksForIt() throws {
        let scheduler = skill("scheduler", "予約", triggers: ["予約"], confirm: true)
        #expect(try resolved("予約して", [scheduler])?.confirmReason != nil)
    }

    // MARK: 実際のスキル（todo-remind）の規則

    /// 規則は、**スキルの SKILL.md にある**（コアではなく）。`corpus/schedule.tsv`：dev＝規則を決めるとき見た文・test・test3＝決めたあとで、1 度だけ測った文。
    @Test func theTodoRemindSkillsOwnTriggersSeparateReservationPhrasingsFromNeighbouringOnes() throws {
        let file = Self.root.appendingPathComponent(".voice-control/skills/todo-remind/SKILL.md")
        let todo = try SkillStore.parse(String(contentsOf: file, encoding: .utf8), directoryName: "todo-remind", file: file).get()
        #expect(!todo.triggers.isEmpty)
        let corpus = try String(contentsOf: Self.root.appendingPathComponent("corpus/schedule.tsv"), encoding: .utf8)
        var counts: [String: Int] = [:]
        for line in corpus.split(separator: "\n") where !line.hasPrefix("#") {
            let cells = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard cells.count == 3 else { continue }
            counts[cells[0], default: 0] += 1
            #expect(todo.isTriggered(by: cells[2]) == (cells[1] == "yes"), "\(cells[0]): \(cells[2])")
        }
        #expect(counts["dev"] ?? 0 >= 20 && counts["test"] ?? 0 >= 14 && counts["test3"] ?? 0 >= 10 && counts["test4"] ?? 0 >= 10)
    }
}

import Foundation
import Testing
import TestSupport
@testable import VCSkill
import VCCore
import VCDecision

/// 「時刻に実行する予約」の言い方の規則（`corpus/schedule.tsv`）と、スキルの解決への効き方。
@Suite struct ScheduledRequestTests {
    private static let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("corpus/schedule.tsv")

    private func rows(_ set: String) throws -> [(expected: Bool, text: String)] {
        try String(contentsOf: Self.corpus, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", maxSplits: 2).map(String.init) }.filter { $0.count == 3 && $0[0] == set }
            .map { ($0[1] == "yes", $0[2]) }
    }

    @Test func reservationPhrasingsAreRecognisedAndNeighbouringPhrasingsAreNot() throws {
        for set in ["dev", "test"] {
            let table = try rows(set)
            #expect(table.count >= 20, "\(set)")
            for row in table { #expect(ScheduledRequest.matches(row.text) == row.expected, "\(set): \(row.text)") }
        }
    }

    @Test func fullWidthDigitsAndSpacesAreRead() {
        #expect(ScheduledRequest.matches("１０時に　音楽をかけるよう予約して") && ScheduledRequest.matches("午後 3 時に曲を止めるようにスケジュールして"))
    }

    private func skill(_ name: String, _ description: String) -> Skill {
        Skill(name: name, description: description, allowedCommands: ["echo"], confirm: false, body: "x", file: URL(string: "builtin:\(name)")!, scope: .global)
    }

    @Test func aReservationGoesToTheSchedulerEvenWhenTheRouterPrefersAnotherSkillButOnlyWhenItIsEnabled() throws {
        let spotify = skill("spotify", "Spotify の操作"), scheduler = skill(ScheduledRequest.skillName, "今日の Todo")
        func resolved(_ request: String, _ skills: [Skill]) throws -> String? {
            let resolver = SkillResolver(scorer: SkillScorer(routedDescription: "Spotify の操作"), skills: skills, gate: Gate())
            guard case let .resolved(r) = try resolver.resolve(request) else { return nil }
            return r.skill.name
        }
        #expect(try resolved("11時に音楽を流すよう予約して", [spotify, scheduler]) == ScheduledRequest.skillName)
        #expect(try resolved("11時に音楽を流すよう予約して", [spotify]) == "spotify")   // 入っていない・無効なら、いままでどおり
        #expect(try resolved("音楽を流して", [spotify, scheduler]) == "spotify")   // 予約でなければ、Tiny-Jev の選択
    }
}

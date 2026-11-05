import Foundation
import Testing
import VCDecision
@testable import VCSkill

/// Tiny-Jev での選択（`vc pick`）：確信できたときだけ「選んだ」。迷えば「迷っている」（利用者に聞く）。
@Suite struct PickerTests {
    /// 決まった確率（候補の分 + 「どれでもない」）を返す偽物。受け取った候補も記録する。
    private final class Fixed: OptionScorer, @unchecked Sendable {
        let probabilities: [Double]
        private let lock = NSLock(); private(set) var seen: [[String]] = []
        init(_ p: [Double]) { probabilities = p }
        func score(state: String, question: String, options: [String]) throws -> [Double] {
            lock.lock(); seen.append(options); lock.unlock()
            return Array(probabilities.prefix(options.count))
        }
    }

    private let options = ["請求書_10月.pdf — 経理（pdf・10/28）", "請求書_9月.pdf — 経理（pdf・09/30）", "見積書.pdf — 経理（pdf・10/15）"]

    @Test func aConfidentTopIsPicked() throws {
        let r = try Picker.pick(query: "請求書の10月", options: options, scorer: Fixed([0.85, 0.08, 0.04, 0.03]))
        #expect(r.verdict == .picked(0))
        #expect(Picker.format(r, options: options).hasPrefix("verdict: picked\n請求書_10月.pdf"))
    }

    @Test func anUnsureTopIsAmbiguousWithTheClosestOnesInOrder() throws {
        let r = try Picker.pick(query: "請求書", options: options, scorer: Fixed([0.45, 0.40, 0.10, 0.05]))
        #expect(r.verdict == .ambiguous([0, 1, 2]))
        #expect(Picker.format(r, options: options).contains("ask the user which one: 1, 2, 3"))
    }

    @Test func noneWinsWhenNothingFits() throws {
        let r = try Picker.pick(query: "関係ない", options: options, scorer: Fixed([0.05, 0.05, 0.05, 0.85]))
        #expect(r.verdict == .none)
        #expect(Picker.format(r, options: options).hasPrefix("verdict: none"))
    }

    @Test func anEmptyListIsNoneWithoutAskingTheModel() throws {
        let scorer = Fixed([1])
        #expect(try Picker.pick(query: "x", options: [], scorer: scorer).verdict == .none)
        #expect(scorer.seen.isEmpty)
    }

    @Test func theThresholdIsAdjustableAndLongOptionsAreCutBeforeScoring() throws {
        let scorer = Fixed([0.6, 0.3, 0.1])
        #expect(try Picker.pick(query: "x", options: ["a", "b"], threshold: 0.5, scorer: scorer).verdict == .picked(0))
        let long = String(repeating: "あ", count: 300)
        let capture = Fixed([0.9, 0.1]); _ = try Picker.pick(query: "x", options: [long], scorer: capture)
        #expect(capture.seen.first?.first?.count == Picker.maxOptionLength)
    }

    /// 候補が多いとき（Tiny-Jev の上限を超える）も、勝ち抜き戦で選べる。
    @Test func moreOptionsThanTheModelAcceptsStillWork() throws {
        let many = (1...80).map { "ファイル\($0).txt" }
        let r = try Picker.pick(query: "x", options: many, scorer: Fixed([0.9] + Array(repeating: 0.001, count: 40)))
        if case .picked = r.verdict {} else if case .ambiguous = r.verdict {} else { Issue.record("勝ち抜き戦で、決まらなかった") }
    }
}

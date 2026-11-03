import Foundation
import TestSupport
import Testing
@testable import VCPCControl
import VCDecision

@Suite struct PCEvalTests {
    private let button = UIElement(ref: "@s:e1", role: "button", name: "Open", actions: ["Click"], bounds: Rect(x: 280, y: 0, width: 20, height: 20))
    private let window = Rect(x: 0, y: 0, width: 300, height: 600)

    private func plan(_ step: Step?, verdict: Gate.Verdict) -> Plan {
        Plan(choice: "c", probability: 0.9, step: step, risk: nil, verdict: verdict, rejection: nil, rounds: 1)
    }

    @Test func canonicalAndStepFromCanonicalAgree() {
        let snapshot = Snapshot(app: "A", elements: [button, RecordingDesktop.area], window: window)
        for s in ["scroll:down", "window:maximize", "press:cmd+c", "click:Open", "open:Notes"] {
            #expect(PCEval.step(fromCanonical: s, snapshot: snapshot).map { PCEval.canonical($0) } == s)
        }
        #expect(PCEval.step(fromCanonical: "click:Missing", snapshot: snapshot) == nil)
        #expect(PCEval.step(fromCanonical: "bogus", snapshot: snapshot) == nil)
        #expect(PCEval.canonical(nil) == "none")
    }

    @Test func aRejectedPlanCountsAsNone() {
        #expect(PCEval.outcome(of: plan(.openApp("A"), verdict: .reject)) == "none")
        #expect(PCEval.outcome(of: plan(.openApp("A"), verdict: .confirm)) == "open:A")
    }

    @Test func judgeComparesAlternativesAndTheRegion() {
        let snapshot = Snapshot(app: "A", elements: [button], window: window)
        let click = plan(.click(button), verdict: .execute)
        #expect(PCEval.judge(click, expected: "click:Open", snapshot: snapshot).hit)
        #expect(PCEval.judge(click, expected: "click:Open@右上", snapshot: snapshot).hit)
        #expect(!PCEval.judge(click, expected: "click:Open@左下", snapshot: snapshot).hit)
        #expect(PCEval.judge(click, expected: "press:cmd+c|click:Open", snapshot: snapshot).hit)
        #expect(PCEval.judge(click, expected: "press:cmd+c|click:Open", snapshot: snapshot).kind == "press")
    }

    @Test func tallyCountsWrongExecutionsAndLeakedConversation() {
        let snapshot = Snapshot(app: "A", elements: [button], window: window)
        var tally = PCEval.Tally()
        tally.record(PCEval.judge(plan(.click(button), verdict: .execute), expected: "click:Open", snapshot: snapshot))   // 当たり・確認なしで実行
        tally.record(PCEval.judge(plan(.click(button), verdict: .execute), expected: "scroll:down", snapshot: snapshot))  // 危険な誤り
        tally.record(PCEval.judge(plan(.click(button), verdict: .confirm), expected: "none", snapshot: snapshot))         // 会話が通った
        tally.record(PCEval.judge(plan(nil, verdict: .reject), expected: "none", snapshot: snapshot))                     // 会話を捨てた
        #expect((tally.total, tally.hits, tally.wrongExecuted) == (4, 2, 1))
        #expect((tally.positives, tally.positiveExecuted) == (2, 1))
        #expect((tally.negatives, tally.negativeLeaked) == (2, 1))
        #expect(tally.byKind["click"]?.hit == 1 && tally.byKind["click"]?.total == 1)
    }

    @Test func llmTallyUsesTheHybridRule() {
        let snapshot = Snapshot(app: "A", elements: [button], window: window)
        var tally = PCEval.LLMTally()
        let executed = PCEval.judge(plan(.click(button), verdict: .execute), expected: "scroll:down", snapshot: snapshot)
        let wrong = tally.record(llmGot: "click:Open", against: executed)   // 一致して、ゲートが「実行」＝ 誤って確認なしで実行
        let right = tally.record(llmGot: "scroll:down", against: executed)
        #expect(!wrong && right)
        #expect((tally.hits, tally.wrongAny, tally.hybridWrongExecuted, tally.hybridPositiveExecuted) == (1, 1, 1, 0))
    }

    @Test func rowsSkipCommentsAndShortLinesAndKeepTabsInTheLastColumn() {
        let text = "# コメント\n\na\tb\tc\td\nx\ty\n"
        #expect(PCEval.rows(in: text, columns: 3) == [["a", "b", "c\td"]])
        #expect(PCEval.rows(in: text, columns: 4) == [["a", "b", "c", "d"]])
    }
}

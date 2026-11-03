import Foundation
import Testing
import VCDecision
import VCPCControl
@testable import vc

/// 端末の色の指定（端末で実行したときだけ付く）を取り除く。
private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }

private final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Value] = []
    func add(_ value: Value) { lock.lock(); all.append(value); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return all }
}

/// どの発話も「どれでもない」と選ぶ偽物（`Planner` が、実行しない判定の `Plan` を作る）。
private struct NoneScorer: OptionScorer {
    func score(state: String, question: String, options: [String]) throws -> [Double] {
        var p = options.map { _ in 0.001 }
        p[options.count - 1] = 0.9
        return p
    }
}

private struct EmptyDesktop: Desktop {
    func snapshot() throws -> Snapshot { Snapshot(app: "", elements: []) }
    func apps() throws -> [String] { [] }
    func perform(_ step: Step) throws {}
}

private func rejectedPlan() throws -> Plan { try Planner(scorer: NoneScorer(), desktop: EmptyDesktop()).plan("雑談") }

private let step = Step.openApp("Notes")

@Suite struct TerminalPCReporterTests {
    private func reporter() -> (reporter: TerminalPCReporter, out: Collected<String>) {
        let out = Collected<String>()
        return (TerminalPCReporter(out: { out.add(plain($0)) }), out)
    }

    @Test func onlyAnActDryRunSaysItDidNotExecute() {
        let t = reporter()
        [PCEvent.planOnly(step), .dryRun(step)].forEach(t.reporter.report)
        #expect(t.out.values == ["  dry-run：実行していない（--execute で実行）"])
    }

    @Test func theRestIsCancelledOnlyWhenThereIsARest() throws {
        let t = reporter()
        let plan = try rejectedPlan()
        [PCEvent.rejected(plan, cancelsRemaining: true), .rejected(plan, cancelsRemaining: false),
         .notConfirmed(step, cancelsRemaining: true), .notConfirmed(step, cancelsRemaining: false)].forEach(t.reporter.report)
        #expect(t.out.values == ["  → 実行しない（残りも中止）", "  → 実行しない", "  やめた（確認が取れない）。残りも中止", "  やめた（確認が取れない）"])
    }

    @Test func aClauseHeadingNumbersOnlyWhenThereAreSeveral() {
        let t = reporter()
        [PCEvent.clause(index: 1, count: 1, text: "A"), .clause(index: 2, count: 3, text: "B")].forEach(t.reporter.report)
        #expect(t.out.values == ["\n▶ A", "\n▶ [2/3] B"])
    }

    @Test func confirmationIsNotAskedOnTheTerminal() {
        let t = reporter()
        [PCEvent.confirmRequired(step), .confirmAnswered(approved: true), .executing(step)].forEach(t.reporter.report)
        #expect(t.out.values.isEmpty)
    }
}

@Suite struct HUDPCReporterTests {
    private struct Shown { let content: HUDContent; let hideAfter: TimeInterval? }

    private func reporter() -> (reporter: HUDPCReporter, shown: Collected<Shown>, spoken: Collected<String>, out: Collected<String>) {
        let shown = Collected<Shown>(), spoken = Collected<String>(), out = Collected<String>()
        let reporter = HUDPCReporter(chip: "shift", utterance: "テスト", terminal: TerminalPCReporter(out: { out.add(plain($0)) }),
                                     present: { shown.add(Shown(content: $0, hideAfter: $1)) }, speak: { spoken.add($0) })
        return (reporter, shown, spoken, out)
    }

    @Test func aConfirmedStepWalksThroughConfirmWorkingAndSuccess() {
        let r = reporter()
        r.reporter.begin()
        [PCEvent.confirmRequired(step), .confirmAnswered(approved: true), .executing(step), .executed(step)].forEach(r.reporter.report)
        r.reporter.finish()

        let shown = r.shown.values
        #expect(shown.map(\.content.title) == ["考え中", "実行しますか？", "実行中", "実行中", "実行中", "完了"])
        #expect(shown.map(\.content.phase) == [.working, .confirm, .working, .working, .working, .success])
        #expect(shown[0].content.chip == "shift" && shown[0].content.heard == "テスト")
        #expect(shown[1].content.hint == "\(step.spoken)　もう一度押して「はい」")
        #expect(shown[3].content.steps.map(\.command) == [step.summary])
        #expect(String(describing: shown[4].content.steps[0].status) == "ok")
        #expect(shown[5].hideAfter == 3 && shown.dropLast().allSatisfy { $0.hideAfter == nil })
        #expect(r.spoken.values == ["\(step.spoken)。実行しますか"])
        #expect(r.out.values == ["  ! 確認待ち：もう一度トリガーを押して「はい」と言う", "  ✓ done"])
    }

    @Test func aDeclinedConfirmationIsADeniedStepAndNothingWasDone() {
        let r = reporter()
        [PCEvent.confirmRequired(step), .confirmAnswered(approved: false), .notConfirmed(step, cancelsRemaining: false)].forEach(r.reporter.report)
        r.reporter.finish()
        let last = r.shown.values.last!
        #expect(last.content.title == "実行しませんでした" && last.content.phase == .info)
        #expect(last.content.steps.map(\.command) == [step.summary] && last.content.steps[0].output == "やめました")
        #expect(String(describing: last.content.steps[0].status) == "denied")
    }

    @Test func aRejectedPlanShowsItsReasonAndADryRunIsDenied() throws {
        let r = reporter()
        let plan = try rejectedPlan()
        [PCEvent.rejected(plan, cancelsRemaining: false), .dryRun(step)].forEach(r.reporter.report)
        let steps = r.shown.values.last!.content.steps
        #expect(steps.map(\.command) == [plan.choice, step.summary])
        #expect(steps.map(\.output) == [plan.rejection, "実行していません（--execute なし）"])
        #expect(r.spoken.values.isEmpty)
    }
}

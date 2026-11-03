import Foundation
import TestSupport
import Testing
import VCDecision
import VCPCControl
@testable import vc

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

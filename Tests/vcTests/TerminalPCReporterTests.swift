import Foundation
import TestSupport
import Testing
import VCDecision
import VCPCControl
@testable import vc

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

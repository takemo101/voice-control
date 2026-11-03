import Foundation
import TestSupport
import Testing
@testable import VCPCControl
import VCCore
import VCDecision

@Suite struct PCRunnerTests {
    private static let scrollDown = (option: ScrollDirection.down.option, p: 0.95)
    private static let closeTab = (option: "キー操作: " + (Shortcut.all.first { $0.combo == "cmd+w" }!.option), p: 0.95)
    private static let scrollStep = Step.scroll(.down, RecordingDesktop.area)
    private static let closeStep = Step.press(Shortcut.all.first { $0.combo == "cmd+w" }!)

    private func make(_ picks: [String: (option: String, p: Double)], mode: PCRunner.Mode, usesHistory: Bool = true, desktop: RecordingDesktop = RecordingDesktop()) -> (runner: PCRunner, desktop: RecordingDesktop) {
        let planner = Planner(scorer: UtteranceScorer(picks: picks), desktop: desktop)
        return (PCRunner(planner: planner, desktop: desktop, mode: mode, usesHistory: usesHistory, settle: .zero), desktop)
    }

    @Test func aRejectedClauseStopsTheRest() async throws {
        let (runner, desktop) = make(["雑談": ("", 0), "下": Self.scrollDown], mode: .execute)
        let reporter = Recorder()
        try await runner.run(clauses: ["雑談", "下"], reporter: reporter, cancel: nil, confirm: { Issue.record("確認は要らない"); return true })
        #expect(reporter.tags == ["clause 1/2", "planned", "rejected+cancels"])
        #expect(desktop.performed.isEmpty)
        #expect(runner.history.entries.isEmpty)
    }

    @Test func declinedConfirmationStopsTheRestWithoutExecuting() async throws {
        let (runner, desktop) = make(["閉じて": Self.closeTab, "下": Self.scrollDown], mode: .execute)
        let reporter = Recorder()
        try await runner.run(clauses: ["閉じて", "下"], reporter: reporter, cancel: nil, confirm: { false })
        #expect(reporter.tags == ["clause 1/2", "planned", "confirmRequired", "answered false", "notConfirmed+cancels"])
        #expect(desktop.performed.isEmpty)
        #expect(runner.history.entries.isEmpty)
    }

    @Test func approvedConfirmationExecutesAndContinues() async throws {
        let (runner, desktop) = make(["閉じて": Self.closeTab, "下": Self.scrollDown], mode: .execute)
        let reporter = Recorder()
        var asked = 0
        try await runner.run(clauses: ["閉じて", "下"], reporter: reporter, cancel: nil, confirm: { asked += 1; return true })
        #expect(asked == 1)   // 確認が要るのは、1 手目だけ
        #expect(reporter.tags == ["clause 1/2", "planned", "confirmRequired", "answered true", "executing", "executed",
                                  "clause 2/2", "planned", "executing", "executed"])
        #expect(desktop.performed == [Self.closeStep, Self.scrollStep])
    }

    @Test func cancellationBeforeAClauseThrowsWithoutPlanning() async {
        let (runner, desktop) = make(["下": Self.scrollDown], mode: .execute)
        let token = CancelToken()
        token.cancel()
        let reporter = Recorder()
        await #expect(throws: CancellationError.self) { try await runner.run(clauses: ["下"], reporter: reporter, cancel: token, confirm: { true }) }
        #expect(reporter.tags == ["clause 1/1"])
        #expect(desktop.performed.isEmpty)
    }

    @Test func cancellationDuringConfirmationStopsBeforeExecuting() async {
        let (runner, desktop) = make(["閉じて": Self.closeTab], mode: .execute)
        let token = CancelToken()
        let reporter = Recorder()
        await #expect(throws: CancellationError.self) {
            try await runner.run(clauses: ["閉じて"], reporter: reporter, cancel: token, confirm: { token.cancel(); return true })
        }
        #expect(reporter.tags == ["clause 1/1", "planned", "confirmRequired", "answered true", "executing"])
        #expect(desktop.performed.isEmpty)
        #expect(runner.history.entries.isEmpty)
    }

    @Test func dryRunPlansEveryClauseButNeverExecutesOrAsks() async throws {
        let (runner, desktop) = make(["下": Self.scrollDown, "閉じて": Self.closeTab], mode: .dryRun)
        let reporter = Recorder()
        try await runner.run(clauses: ["下", "閉じて"], reporter: reporter, cancel: nil, confirm: { Issue.record("問い合わせない"); return true })
        #expect(reporter.tags == ["clause 1/2", "planned", "dryRun", "clause 2/2", "planned", "dryRun"])
        #expect(desktop.performed.isEmpty)
        #expect(runner.history.entries.isEmpty)
    }

    @Test func planModeOnlyShowsThePlan() async throws {
        let (runner, desktop) = make(["下": Self.scrollDown], mode: .plan)
        let reporter = Recorder()
        try await runner.run(clauses: ["下"], reporter: reporter, cancel: nil, confirm: { true })
        #expect(reporter.tags == ["clause 1/1", "planned", "planOnly"])
        #expect(desktop.performed.isEmpty)
    }

    @Test func executionIsRecordedInTheHistoryAndTheNextClauseUsesIt() async throws {
        let again = (option: "直前の操作をもう一度する（\(ScrollDirection.down.option)）", p: 0.95)
        let (runner, desktop) = make(["下": Self.scrollDown, "もう一回": again], mode: .execute)
        try await runner.run(clauses: ["下", "もう一回"], reporter: Recorder(), cancel: nil, confirm: { Issue.record("確認は要らない"); return true })
        #expect(desktop.performed == [Self.scrollStep, Self.scrollStep])
        #expect(runner.history.entries.map(\.step) == [Self.scrollStep, Self.scrollStep])
    }

    @Test func withoutContextThePreviousStepIsNotOfferedButStillRecorded() async throws {
        let again = (option: "直前の操作をもう一度する（\(ScrollDirection.down.option)）", p: 0.95)
        let (runner, desktop) = make(["下": Self.scrollDown, "もう一回": again], mode: .execute, usesHistory: false)
        let reporter = Recorder()
        try await runner.run(clauses: ["下", "もう一回"], reporter: reporter, cancel: nil, confirm: { true })
        #expect(reporter.tags == ["clause 1/2", "planned", "executing", "executed", "clause 2/2", "planned", "rejected"])
        #expect(desktop.performed == [Self.scrollStep])
        #expect(runner.history.entries.map(\.step) == [Self.scrollStep])
    }

    @Test func aFailedExecutionIsThrownAndNotRecorded() async {
        let desktop = RecordingDesktop()
        desktop.failure = AgentDesktop.Failure.noOutput(1)
        let (runner, _) = make(["下": Self.scrollDown, "閉じて": Self.closeTab], mode: .execute, desktop: desktop)
        let reporter = Recorder()
        await #expect(throws: AgentDesktop.Failure.self) { try await runner.run(clauses: ["下", "閉じて"], reporter: reporter, cancel: nil, confirm: { true }) }
        #expect(reporter.tags == ["clause 1/2", "planned", "executing"])
        #expect(runner.history.entries.isEmpty)
    }

    @Test func splitsAnUtteranceByRuleBeforeRunning() async throws {
        let (runner, desktop) = make(["下にスクロールして": Self.scrollDown], mode: .execute)
        let reporter = Recorder()
        try await runner.run("下にスクロールして、そのあと下にスクロールして", reporter: reporter, confirm: { true })
        #expect(reporter.tags.filter { $0.hasPrefix("clause") } == ["clause 1/2", "clause 2/2"])
        #expect(desktop.performed.count == 2)
    }
}

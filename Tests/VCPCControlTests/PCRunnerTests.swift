import Foundation
import Testing
@testable import VCPCControl
import VCCore
import VCDecision

/// 操作を記録する `Desktop`（画面は、スクロール領域が 1 つ。`failure` があれば、`perform` が失敗する）。
private final class FakeDesktop: Desktop, @unchecked Sendable {
    static let area = UIElement(ref: "@s:e1", role: "scrollarea", name: "notes", actions: ["Scroll"])
    private let lock = NSLock()
    private var items: [Step] = []
    var failure: Error?

    var performed: [Step] { lock.lock(); defer { lock.unlock() }; return items }
    func snapshot() throws -> Snapshot { Snapshot(app: "", elements: [Self.area]) }
    func apps() throws -> [String] { [] }
    func perform(_ step: Step) throws {
        if let failure { throw failure }
        lock.lock(); items.append(step); lock.unlock()
    }
}

/// 発話ごとに、選ぶ選択肢と確率を決めておく偽物（決めていない発話は、会話＝「どれでもない」）。取り消しにくさの問い（no／yes）には、`risk`。
private struct ScriptedScorer: OptionScorer {
    let picks: [String: (option: String, p: Double)]
    var risk = 0.0

    func score(state: String, question: String, options: [String]) throws -> [Double] {
        if options == ["no", "yes"] { return [1 - risk, risk] }
        let utterance = state.split(separator: "\n").last.map(String.init) ?? state
        var p = options.map { _ in 0.001 }
        if let pick = picks[utterance], let i = options.firstIndex(of: pick.option) { p[i] = pick.p } else { p[options.count - 1] = 0.9 }
        let sum = p.reduce(0, +)
        return p.map { $0 / sum }
    }
}

/// 出来事を、短い文字にして集める。
private final class Recorder: PCReporter {
    private(set) var tags: [String] = []

    func report(_ event: PCEvent) {
        switch event {
        case .llmSplit, .llmSplitFailed: tags.append("split")
        case let .clause(i, n, _): tags.append("clause \(i)/\(n)")
        case .planned: tags.append("planned")
        case let .rejected(_, cancels): tags.append("rejected" + (cancels ? "+cancels" : ""))
        case .planOnly: tags.append("planOnly")
        case .dryRun: tags.append("dryRun")
        case .confirmRequired: tags.append("confirmRequired")
        case let .confirmAnswered(approved): tags.append("answered \(approved)")
        case let .notConfirmed(_, cancels): tags.append("notConfirmed" + (cancels ? "+cancels" : ""))
        case .executing: tags.append("executing")
        case .executed: tags.append("executed")
        }
    }
}

@Suite struct PCRunnerTests {
    private static let scrollDown = (option: ScrollDirection.down.option, p: 0.95)
    private static let closeTab = (option: "キー操作: " + (Shortcut.all.first { $0.combo == "cmd+w" }!.option), p: 0.95)
    private static let scrollStep = Step.scroll(.down, FakeDesktop.area)
    private static let closeStep = Step.press(Shortcut.all.first { $0.combo == "cmd+w" }!)

    private func make(_ picks: [String: (option: String, p: Double)], mode: PCRunner.Mode, usesHistory: Bool = true, desktop: FakeDesktop = FakeDesktop()) -> (runner: PCRunner, desktop: FakeDesktop) {
        let planner = Planner(scorer: ScriptedScorer(picks: picks), desktop: desktop)
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
        let desktop = FakeDesktop()
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

@Suite struct PCEvalTests {
    private let button = UIElement(ref: "@s:e1", role: "button", name: "Open", actions: ["Click"], bounds: Rect(x: 280, y: 0, width: 20, height: 20))
    private let window = Rect(x: 0, y: 0, width: 300, height: 600)

    private func plan(_ step: Step?, verdict: Gate.Verdict) -> Plan {
        Plan(choice: "c", probability: 0.9, step: step, risk: nil, verdict: verdict, rejection: nil, rounds: 1)
    }

    @Test func canonicalAndStepFromCanonicalAgree() {
        let snapshot = Snapshot(app: "A", elements: [button, FakeDesktop.area], window: window)
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

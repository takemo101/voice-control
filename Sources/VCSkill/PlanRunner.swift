import Foundation
import VCCore

/// 依頼を、複数のステップに分けて、順に実行する（`vc run`・声の流れ）。
/// **分け方を決めるのは、言語モデル**（`RequestPlanning`）。ここは、分け方の案を受けて、ステップごとに、**これまでの経路**（Tiny-Jev が選ぶ → 確認 → 実行）を通すだけ：
/// - 許可の照合（`CommandPolicy`）・確認は、ステップごと（スキルごと）に、いまのまま。ステップの結果で、許可は広がらない。
/// - 分けなかった（`.single`）・案が使えなかったときは、**いまの 1 依頼の動きと同じ**（`SkillRunner.run` を 1 回）。
/// - 最初の失敗（失敗の返事・拒否・確認の却下・取りやめ）で止まる。済んだステップは、元に戻さない。
/// - 前のステップの結果は、次のスキルが `accepts-previous` のときだけ、信頼しないデータとして渡す。
public struct PlanRunner: Sendable {
    private let runner: SkillRunner
    private let planner: RequestPlanning?
    private let dryRun: Bool
    private let cancel: CancelToken?

    /// `planner` が nil なら、分けない（1 依頼 = 1 スキル）。
    public init(runner: SkillRunner, planner: RequestPlanning?, dryRun: Bool, cancel: CancelToken? = nil) {
        self.runner = runner
        self.planner = planner
        self.dryRun = dryRun
        self.cancel = cancel
    }

    public func run(_ request: String, reporter: RunReporter, confirm: () async throws -> Bool) async throws -> RunOutcome {
        guard let planner else { return try await runner.run(request, reporter: reporter, confirm: confirm) }
        let decision: PlanDecision
        do { decision = try await planner.plan(request) }
        catch {
            if cancel?.isCancelled == true || error is CancellationError { reporter.report(.cancelled); return .cancelled }
            decision = PlanDecision(plan: .single, rejection: .unreadable)
        }
        if cancel?.isCancelled == true { reporter.report(.cancelled); return .cancelled }
        guard case let .steps(steps) = decision.plan else { return try await runner.run(request, reporter: reporter, confirm: confirm) }

        reporter.report(.planned(steps: steps))
        var previous: String?
        for (offset, step) in steps.enumerated() {
            if cancel?.isCancelled == true {
                reporter.report(.cancelled)
                reporter.report(.planStopped(completed: offset, total: steps.count))
                return .cancelled
            }
            reporter.report(.stepStarted(index: offset + 1, total: steps.count, text: step))
            let recorder = StepRecorder(reporter)
            let outcome = try await runner.run(step, reporter: recorder, previousResult: previous, confirm: confirm)
            let reply = recorder.reply
            // 成功は、返事が `done` のとき（`failed:`・`skip:` の返事は、実行者が「できなかった」と言っている）。dry-run は、実行していないので、返事を見ない
            let succeeded = outcome == .completed && (dryRun || reply?.lowercased().hasPrefix("done") == true)
            guard succeeded else {
                reporter.report(.planStopped(completed: offset, total: steps.count))
                return outcome == .completed ? .failed : outcome
            }
            previous = reply
        }
        return .completed
    }
}

/// 1 ステップの出来事を、そのまま、先へ渡しながら、返事（`done: …`）を覚える。
/// `@unchecked Sendable` の理由：可変な状態（`last`）は、`lock` で守る。
private final class StepRecorder: RunReporter, @unchecked Sendable {
    private let inner: RunReporter
    private let lock = NSLock()
    private var last: String?

    init(_ inner: RunReporter) { self.inner = inner }

    var reply: String? { lock.lock(); defer { lock.unlock() }; return last }

    func report(_ event: RunEvent) {
        if case let .reply(text, _, _) = event { lock.lock(); last = text; lock.unlock() }
        inner.report(event)
    }
}

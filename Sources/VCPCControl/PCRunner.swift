import Foundation
import VCCore
import VCDecision

/// PC 操作の流れ：発話を 1 手ずつに分け、順に、計画 → 門（ゲート）→ 確認 → 実行 → 履歴。
/// 規則（実行してよいか・確認が要るか・取りやめ）は、ここに置く。表示・読み上げ・終了コードは持たない（出来事を `PCReporter` へ送るだけ）。
/// 計画・実行の失敗と、`confirm` の失敗は、そのまま投げる。
public struct PCRunner: Sendable {
    public enum Mode: Sendable, Equatable {
        /// いまの画面で、各手を計画して見せるだけ（前の手の結果は、反映されない）。
        case plan
        /// 計画して、実行はしない（`--execute` なし）。
        case dryRun
        /// 実行する。前の手を実行したあとの画面で、次の手を計画する。
        case execute
    }

    private let planner: Planner
    private let desktop: Desktop
    private let mode: Mode
    private let usesHistory: Bool
    private let llmSplit: Bool
    private let settle: Duration
    /// これまでに実行した手（前の指示を、次の判断の文脈に使う）。この `PCRunner` が持つ。
    let history = HistoryStore()

    /// `usesHistory`：前の指示を、文脈に使う（`--no-context` なら false。実行した手の記録は、false でも積む）。
    /// `llmSplit`：発話を、言語モデルで分ける（使えないときは、ルール）。`settle`：手と手の間の、画面が落ち着くのを待つ時間。
    public init(planner: Planner, desktop: Desktop, mode: Mode, usesHistory: Bool = true, llmSplit: Bool = false, settle: Duration = .milliseconds(800)) {
        self.planner = planner
        self.desktop = desktop
        self.mode = mode
        self.usesHistory = usesHistory
        self.llmSplit = llmSplit
        self.settle = settle
    }

    /// 発話を、1 手ずつに分けて、順に処理する。どれかの手が「実行しない」になれば、残りも中止する。
    /// `confirm`：確認が要る手を、実行の前に呼ぶ（承認なら true。承認されなければ、その手と残りを中止する）。`cancel`：取りやめの合図（来たら `CancellationError`）。
    public func run(_ utterance: String, reporter: PCReporter, cancel: CancelToken? = nil, confirm: () async throws -> Bool) async throws {
        try await run(clauses: await clauses(for: utterance, reporter: reporter), reporter: reporter, cancel: cancel, confirm: confirm)
    }

    /// 発話を、1 手ずつに分ける。既定はルール（`ClauseSplitter`）。`llmSplit` なら、言語モデル（FoundationModels）で書き直す（使えない・失敗のときは、ルール）。
    func clauses(for utterance: String, reporter: PCReporter) async -> [String] {
        guard llmSplit else { return ClauseSplitter.split(utterance) }
        do {
            let steps = try await LLMDecomposer().steps(for: utterance)
            if !steps.isEmpty { reporter.report(.llmSplit(steps)); return steps }
        } catch { reporter.report(.llmSplitFailed("\(error)")) }
        return ClauseSplitter.split(utterance)
    }

    func run(clauses: [String], reporter: PCReporter, cancel: CancelToken?, confirm: () async throws -> Bool) async throws {
        for (i, clause) in clauses.enumerated() {
            let more = i + 1 < clauses.count
            reporter.report(.clause(index: i + 1, count: clauses.count, text: clause))
            if cancel?.isCancelled == true { throw CancellationError() }
            let plan = try planner.plan(clause, history: usesHistory ? history.entries : [])
            reporter.report(.planned(plan))
            guard let step = plan.step, plan.verdict != .reject else {
                reporter.report(.rejected(plan, cancelsRemaining: more))
                return
            }
            guard mode == .execute else {
                reporter.report(mode == .dryRun ? .dryRun(step) : .planOnly(step))
                continue
            }
            if plan.verdict == .confirm {
                reporter.report(.confirmRequired(step))
                let approved = try await confirm()
                reporter.report(.confirmAnswered(approved: approved))
                if !approved {
                    reporter.report(.notConfirmed(step, cancelsRemaining: more))
                    return
                }
            }
            reporter.report(.executing(step))
            if cancel?.isCancelled == true { throw CancellationError() }
            try desktop.perform(step)
            history.append(Executed(step: step))
            reporter.report(.executed(step))
            if more { try await Task.sleep(for: settle) }   // 画面が落ち着くのを待つ
        }
    }
}

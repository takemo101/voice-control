import Foundation
import VCCore
import VCDecision

/// スキルの実行の経過（`SkillRunner` が、起きた順に、`RunReporter` へ送る）。表示の仕方は、受け取る側が決める。
public enum RunEvent: Sendable, Equatable {
    /// `--skill` で、スキルを指定した（選ばない）。
    case forced(Skill)
    /// Tiny-Jev がスキルを選んだ。`probability`：選んだ確率。
    case matched(Skill, probability: Double, elapsed: TimeInterval)
    /// どのスキルでもなかったので、既定スキルへ回した。`probability`：操作の依頼である確率、`risk`：取り消しにくい依頼である確率。
    case fellBack(Skill, probability: Double, risk: Double, elapsed: TimeInterval)
    /// 実行しない（会話・独り言など）。`fallbackAvailable`：既定スキルが使える（使えなければ、当てはまるスキルがなく、実行しない）。
    case declined(reason: String, fallbackAvailable: Bool, elapsed: TimeInterval)
    /// 実行の前に、確認が要る。このあと、`confirm` を呼ぶ。
    case confirmRequired(Skill, reason: String)
    /// 確認で、承認されなかった（実行しない）。
    case confirmationDeclined
    /// 確認で、承認された。
    case confirmed
    /// 実行者を呼ぶ（dry-run でも、呼ぶ）。
    case started
    /// 実行するコマンド（dry-run なら、実行しようとしたコマンド）。
    case command(String)
    /// コマンドの結果。
    case result(exitCode: Int32, output: String)
    /// 許可されていないコマンド（実行していない）。
    case denied(command: String, reason: String)
    /// 実行者の返事。`commandCount`：実行したコマンドの数（dry-run なら 0）。
    case reply(String, commandCount: Int, elapsed: TimeInterval)
    /// 実行者が失敗した。
    case failed(String)
    /// 取りやめられた。
    case cancelled
}

/// `RunEvent` の受け手（端末の表示・画面の上の表示など）。実行中のコマンドの出来事は、実行者のスレッドから届くので、どのスレッドからも呼べること。
public protocol RunReporter: Sendable {
    func report(_ event: RunEvent)
}

/// `SkillRunner.run` の結果（終了コードや、次の流れへ回すかは、呼び出し側が、これで決める）。
public enum RunOutcome: Sendable, Equatable {
    /// 実行者が返事を返した。
    case completed
    /// 実行しなかった（`RunEvent.declined`）。
    case declined(fallbackAvailable: Bool)
    /// 確認で、承認されなかった。
    case notConfirmed
    case failed
    case cancelled
}

/// スキルを使う流れ：スキルを選ぶ（または、指定する）→ 必要なら確認 → 実行 → 結果。判断はここに置き、表示・終了コード・声の読み上げは持たない（出来事を `RunReporter` へ送るだけ）。
/// 選ぶときの失敗と、`confirm` の失敗は、そのまま投げる（実行者の失敗だけが、`RunEvent.failed`）。
public struct SkillRunner: Sendable {
    public enum Selection: Sendable {
        /// Tiny-Jev が、`skills`（有効なスキル）から選ぶ。選ばれなければ、既定スキル（`DefaultSkill`）。
        case resolve(skills: [Skill], scorer: OptionScorer, gate: Gate)
        /// このスキルを使う（選ばない）。
        case forced(Skill)
    }

    /// 実行者の作り方（スキル・dry-run・コマンドの知らせ先・取りやめの合図）。
    typealias ExecutorFactory = @Sendable (Skill, Bool, ExecutionDisplay, CancelToken?) -> any SkillExecuting

    private let selection: Selection
    private let dryRun: Bool
    private let cancel: CancelToken?
    private let makeExecutor: ExecutorFactory

    /// 実行者は、`engine` のモデル：`SkillAgent`（Apple の言語モデル。既定）か、`OllamaSkillAgent`（この Mac の Ollama）。
    public init(selection: Selection, dryRun: Bool, cancel: CancelToken? = nil, engine: Engine = .apple) {
        self.init(selection: selection, dryRun: dryRun, cancel: cancel, makeExecutor: { skill, dryRun, display, cancel in
            switch engine {
            case .apple: return SkillAgent(skill: skill, dryRun: dryRun, display: display, cancel: cancel)
            case .ollama(let model): return OllamaSkillAgent(skill: skill, model: model, dryRun: dryRun, display: display, cancel: cancel)
            }
        })
    }

    /// テストで、偽の実行者を渡す。
    init(selection: Selection, dryRun: Bool, cancel: CancelToken? = nil, makeExecutor: @escaping ExecutorFactory) {
        self.selection = selection
        self.dryRun = dryRun
        self.cancel = cancel
        self.makeExecutor = makeExecutor
    }

    /// `confirm`：確認が要るときに呼ぶ（承認なら true）。理由は、直前の `RunEvent.confirmRequired` で渡す。
    public func run(_ request: String, reporter: RunReporter, confirm: () async throws -> Bool) async throws -> RunOutcome {
        let skill: Skill
        var confirmReason: String?
        switch selection {
        case let .forced(forced):
            skill = forced
            confirmReason = forced.confirm ? SkillResolver.confirmRequiredReason : nil
            reporter.report(.forced(forced))
        case let .resolve(skills, scorer, gate):
            let t0 = Date()
            switch try SkillResolver(scorer: scorer, skills: skills, gate: gate).resolve(request) {
            case let .declined(reason, fallbackAvailable):
                reporter.report(.declined(reason: reason, fallbackAvailable: fallbackAvailable, elapsed: Date().timeIntervalSince(t0)))
                return .declined(fallbackAvailable: fallbackAvailable)
            case let .resolved(r):
                switch r.kind {
                case .matched: reporter.report(.matched(r.skill, probability: r.probability, elapsed: Date().timeIntervalSince(t0)))
                case .fallback: reporter.report(.fellBack(r.skill, probability: r.probability, risk: r.risk ?? 0, elapsed: Date().timeIntervalSince(t0)))
                }
                skill = r.skill
                confirmReason = r.confirmReason
            }
        }

        if let reason = confirmReason {
            reporter.report(.confirmRequired(skill, reason: reason))
            guard try await confirm() else {
                reporter.report(.confirmationDeclined)
                return .notConfirmed
            }
            reporter.report(.confirmed)
        }

        reporter.report(.started)
        let executor = makeExecutor(skill, dryRun, ExecutionDisplay(
            onCommand: { reporter.report(.command($0)) },
            onResult: { reporter.report(.result(exitCode: $0, output: $1)) },
            onDenied: { reporter.report(.denied(command: $0, reason: $1)) }), cancel)
        let t1 = Date()
        do {
            // 確認の待ちの間に取りやめられていたら、実行者を呼ばない
            if cancel?.isCancelled == true { throw CancellationError() }
            let reply = try await executor.run(request: request)
            reporter.report(.reply(reply, commandCount: executor.executedCommands.count, elapsed: Date().timeIntervalSince(t1)))
            return .completed
        } catch {
            if cancel?.isCancelled == true || error is CancellationError {
                reporter.report(.cancelled)
                return .cancelled
            }
            reporter.report(.failed("\(error)"))
            return .failed
        }
    }
}

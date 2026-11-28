import Foundation
import VCCore

/// 要約の結果：要約か、テーマに合う話がなかったか、失敗（理由つき）。**どれでも、文字起こしは、止まらない**。
public enum SummaryResult: Equatable, Sendable {
    case summary(String)
    case nothingRelevant
    case failed(SummaryFailure)
}

/// 会議の要約（SPEC F82）：発話の並びを、言語モデルで、まとめる。**言語モデルは、スキルを実行するモデル**（Apple・Ollama・OpenAI 互換。クラウドは、使わない）。
/// - 長い会議は、塊に分けて要約して、途中の要約を、またまとめる（Apple のモデルの文脈は、短い）。
/// - テーマ（`focus`）を渡すと、それに関する話だけ（なければ `nothingRelevant`）。
/// - 出力は、信頼しない：`SummaryGuard` が、囲みの取り出しと、**話にない数字**を、検査する。
public struct Summarizer: Sendable {
    /// プロンプト（固定の約束＋まとめ方）を渡して、答えの文字を得る口（テストで、差し替える）。
    public typealias Complete = @Sendable (_ system: String, _ user: String) async throws -> String

    public let instructions: String
    /// 1 回の呼び出しに、見せる文字数の目安。
    public let chunkBudget: Int
    /// 1 回の呼び出しの時間の上限（秒）。
    public let timeout: TimeInterval
    /// 途中の要約を、まとめる回数の上限。
    public let maxRounds = 3
    private let complete: Complete

    public init(engine: Engine, instructionsSetting: String?, chunkBudget: Int = 2800, timeout: TimeInterval = 60) {
        self.init(instructionsSetting: instructionsSetting, chunkBudget: chunkBudget, timeout: timeout) { system, user in
            try await ModelCall.complete(engine: engine, system: system, user: user)
        }
    }

    public init(instructionsSetting: String?, chunkBudget: Int = 2800, timeout: TimeInterval = 60, complete: @escaping Complete) {
        self.instructions = SummaryPrompt.instructions(setting: instructionsSetting)
        self.chunkBudget = max(200, chunkBudget)
        self.timeout = timeout
        self.complete = complete
    }

    public func summarize(_ lines: [SummaryLine], focus: String? = nil) async -> SummaryResult {
        guard !lines.isEmpty else { return .failed(.empty) }
        let focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var lines = lines
        // テーマがあれば、先に、**そのテーマの発話を、番号で選ぶ**（要約と、作業を分ける）。なければ、「該当なし」
        if let focus {
            switch await pick(lines, focus: focus) {
            case let .success(picked): lines = picked
            case let .failure(why): return .failed(why)
            }
            if lines.isEmpty { return .nothingRelevant }
        }
        var parts: [String] = []
        for chunk in SummaryChunker.chunks(lines, budget: chunkBudget) {
            let source = chunk.map(\.formatted).joined(separator: "\n")
            switch await call(system: SummaryPrompt.system(instructions: instructions, focus: focus, reducing: false), user: SummaryPrompt.user(lines: chunk), source: source) {
            case let .summary(text): parts.append(text)
            case .nothing: continue
            case let .failed(why): return .failed(why)
            }
        }
        if parts.isEmpty { return focus == nil ? .failed(.unreadable) : .nothingRelevant }
        var round = 0
        while parts.count > 1 {
            round += 1
            let groups = SummaryChunker.groups(parts, budget: chunkBudget)
            if round > maxRounds || groups.count >= parts.count { return .failed(.tooLong) }   // 縮まらない・何度やっても終わらない
            var next: [String] = []
            for group in groups {
                if group.count == 1 { next.append(group[0]); continue }
                switch await call(system: SummaryPrompt.system(instructions: instructions, focus: focus, reducing: true), user: SummaryPrompt.user(parts: group), source: group.joined(separator: "\n")) {
                case let .summary(text): next.append(text)
                case .nothing: continue
                case let .failed(why): return .failed(why)
                }
            }
            parts = next
            if parts.isEmpty { return .nothingRelevant }
        }
        return .summary(parts[0])
    }

    /// テーマの発話を選ぶ（塊ごとに、番号を選ばせる）。選んだ発話を、元の順に返す（なければ、空）。
    private func pick(_ lines: [SummaryLine], focus: String) async -> Result<[SummaryLine], SummaryFailure> {
        var picked: [SummaryLine] = []
        for chunk in SummaryChunker.chunks(lines, budget: chunkBudget) {
            let output: String
            switch await ask(system: SummaryPrompt.selectSystem(focus: focus), user: SummaryPrompt.numberedUser(lines: chunk)) {
            case let .success(text): output = text
            case let .failure(why): return .failure(why)
            }
            guard let numbers = SummaryGuard.extractLines(ToolLoopAgent.withoutThinking(output), count: chunk.count) else { return .failure(.unreadable) }
            picked += numbers.map { chunk[$0 - 1] }
        }
        return .success(picked)
    }

    enum Step: Equatable { case summary(String), nothing, failed(SummaryFailure) }

    private func call(system: String, user: String, source: String) async -> Step {
        switch await ask(system: system, user: user) {
        case let .success(output): return Self.decide(output: output, source: source)
        case let .failure(why): return .failed(why)
        }
    }

    /// 言語モデルへの 1 回の呼び出し（時間の上限つき）。失敗は、要約の失敗の種類に直す。
    private func ask(system: String, user: String) async -> Result<String, SummaryFailure> {
        let complete = self.complete
        do { return .success(try await ModelCall.withTimeout(timeout) { try await complete(system, user) }) }
        catch is ModelCall.TimeoutError { return .failure(.timedOut) }
        catch is CancellationError { return .failure(.failed(tr("取りやめ"))) }
        catch { return .failure(.failed("\(error)")) }
    }

    /// モデルの出力 → 1 回の結果（**純粋**：取り出し・検査）。
    static func decide(output: String, source: String) -> Step {
        guard let extracted = SummaryGuard.extract(ToolLoopAgent.withoutThinking(output)) else { return .failed(.unreadable) }
        switch extracted {
        case .nothing: return .nothing
        case let .summary(text):
            if let why = SummaryGuard.check(summary: text, source: source) { return .failed(why) }
            return .summary(text)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

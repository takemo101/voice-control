import Foundation
import FoundationModels
import VCCore

/// 整理の結果：整えた文字か、**元の文字のまま**（理由つき）。**どちらでも、入力は、止まらない**（SPEC F79(4)）。
public enum TidyResult: Equatable, Sendable {
    case tidied(String)
    /// 元の文字を、そのまま使う。`reason` が nil なら、整理の対象でなかった（短い文など：知らせない）。
    case kept(String, reason: TidyRejection?)

    /// 入力する文字。
    public var text: String {
        switch self {
        case let .tidied(text), let .kept(text, _): return text
        }
    }
}

/// 認識した文字を、言語モデルで整える（整理モード。SPEC F79）。**言語モデルは、スキルを実行するモデル**（`Engine`：Apple・Ollama・OpenAI 互換）。
/// 出力は、信頼しない：`TidyGuard` が、取り出し・数字・否定・長さを、検査する。通らない・遅い・失敗は、**元の文字**。
public struct Tidier: Sendable {
    public let engine: Engine
    /// 設定 `tidyInstructions`（なければ、既定）。
    public let instructions: String
    /// 時間の上限（秒）。
    public let timeout: TimeInterval

    public init(engine: Engine, instructionsSetting: String?, timeout: TimeInterval = 10) {
        self.engine = engine
        self.instructions = TidyPrompt.instructions(setting: instructionsSetting)
        self.timeout = timeout
    }

    public func tidy(_ text: String) async -> TidyResult {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= TidyGuard.minimumLength else { return .kept(text, reason: nil) }
        let system = TidyPrompt.system(instructions: instructions), user = TidyPrompt.user(text: text)
        let output: String
        let engine = self.engine
        do { output = try await ModelCall.withTimeout(timeout) { try await ModelCall.complete(engine: engine, system: system, user: user) } }
        catch is ModelCall.TimeoutError { return .kept(text, reason: .timedOut) }
        catch is CancellationError { return .kept(text, reason: .failed(tr("取りやめ"))) }
        catch { return .kept(text, reason: .failed("\(error)")) }
        return Self.decide(output: output, original: text)
    }

    /// モデルの出力 → 結果（**純粋**：取り出し・検査）。
    static func decide(output: String, original: String) -> TidyResult {
        let reply = ToolLoopAgent.withoutThinking(output)
        guard let tidied = TidyGuard.extract(reply) ?? TidyGuard.untagged(reply, original: original) else { return .kept(original, reason: .unreadable) }
        if let why = TidyGuard.check(original: original, tidied: tidied) { return .kept(original, reason: why) }
        return .tidied(tidied)
    }
}

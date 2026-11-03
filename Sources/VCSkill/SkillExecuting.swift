import Foundation

/// スキルの実行者。`SkillRunner` が必要とする分だけ（実装は `SkillAgent` の 1 つ。テストでは偽物を渡す）。
public protocol SkillExecuting: Sendable {
    /// 実行したコマンド（拒否したものを除く）。
    var executedCommands: [String] { get }
    /// 依頼を実行して、返事（`done: …` / `failed: …`）を返す。取りやめられたら `CancellationError`。
    func run(request: String) async throws -> String
}

/// 実行者が、コマンド・結果・拒否を知らせる先。どのスレッドからも呼ばれる。
public struct ExecutionDisplay: Sendable {
    public var onCommand: @Sendable (String) -> Void
    public var onResult: @Sendable (_ exitCode: Int32, _ output: String) -> Void
    public var onDenied: @Sendable (_ command: String, _ reason: String) -> Void
    public init(onCommand: @escaping @Sendable (String) -> Void, onResult: @escaping @Sendable (Int32, String) -> Void, onDenied: @escaping @Sendable (String, String) -> Void) {
        self.onCommand = onCommand; self.onResult = onResult; self.onDenied = onDenied
    }
}

import Foundation

/// スキルの実行者。`SkillRunner` が必要とする分だけ（実装は `SkillAgent` の 1 つ。テストでは偽物を渡す）。
protocol SkillExecuting: Sendable {
    /// 実行したコマンド（拒否したものを除く）。
    var executedCommands: [String] { get }
    /// 依頼を実行して、返事（`done: …` / `failed: …`）を返す。取りやめられたら `CancellationError`。
    func run(request: String) async throws -> String
    /// 実行の途中で、できた文書（`vc see` の答え）。あれば、ウィンドウに出す。
    var producedDocument: String? { get }
    /// 実行の途中で、保存した画像（`vc image` の結果）。あれば、パネルに出す。
    var producedImage: URL? { get }
}

extension SkillExecuting {
    var producedDocument: String? { nil }
    var producedImage: URL? { nil }
}

/// 実行者が、コマンド・結果・拒否を知らせる先。どのスレッドからも呼ばれる。
struct ExecutionDisplay: Sendable {
    var onCommand: @Sendable (String) -> Void
    var onResult: @Sendable (_ exitCode: Int32, _ output: String) -> Void
    var onDenied: @Sendable (_ command: String, _ reason: String) -> Void
    init(onCommand: @escaping @Sendable (String) -> Void, onResult: @escaping @Sendable (Int32, String) -> Void, onDenied: @escaping @Sendable (String, String) -> Void) {
        self.onCommand = onCommand; self.onResult = onResult; self.onDenied = onDenied
    }
}

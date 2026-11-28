import Foundation
import FoundationModels
import VCCore

/// 言語モデルへの 1 回の呼び出し（整理〔F79〕・要約〔F82〕が、共有する）。**言語モデルは、スキルを実行するモデル**（Apple・Ollama・OpenAI 互換。クラウドは、使わない）。
enum ModelCall {
    struct TimeoutError: Error {}

    /// 使えない（Apple のモデルが、オンになっていない・準備中）。
    struct Unavailable: Error, CustomStringConvertible {
        var description: String { tr("Apple のモデルが使えません") }
    }

    /// 1 回、答えさせる（温度 0）。サーバーのエンジンなら、そのサーバーへ。なければ、Apple のモデル。
    static func complete(engine: Engine, system: String, user: String) async throws -> String {
        if let chat = engine.makeChat() {
            let reply = try await chat.chat([ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)], tools: false)
            return reply.content
        }
        guard case .available = SystemLanguageModel.default.availability else { throw Unavailable() }
        let session = LanguageModelSession(instructions: system)
        return try await session.respond(to: user, options: GenerationOptions(temperature: 0)).content
    }

    /// `seconds` 以内に終わらなければ、`TimeoutError`（終わらなかった側は、取りやめる）。
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw TimeoutError() }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimeoutError() }
            return first
        }
    }
}

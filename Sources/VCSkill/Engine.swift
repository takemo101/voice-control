import Foundation

/// スキルを実行するモデル。既定は、Apple のオンデバイスの言語モデル。ほかは、この Mac のローカルのサーバー（`127.0.0.1`）のモデルに替えられる。
/// スキルを選ぶ Tiny-Jev は、どれでも同じ。
public enum Engine: Sendable, Equatable {
    case apple
    /// Ollama のモデル名（例：`qwen3.5:4b`）。通信先は `127.0.0.1:11434`。
    case ollama(model: String)
    /// OpenAI 互換のサーバー（LM Studio・llama.cpp のサーバー・vLLM・Jan など）のモデルと、**この Mac の**ポート。
    case openAI(model: String, port: Int)

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case invalidModel(String)
        case cloudModel(String)
        case invalidPort(String)
        public var description: String {
            switch self {
            case .unknown(let s): return "エンジン「\(s)」は使えません（apple・ollama:<モデル>・openai:<モデル>@<ポート>。例：ollama:qwen3.5:4b・openai:qwen3-4b@1234）"
            case .invalidModel(let m): return "モデル名「\(m)」が使えません（英数字・. _ : / - だけ）"
            case .cloudModel(let m): return "「\(m)」は、クラウドのモデルです。音声・画面の内容を、外へ出さないので、使えません"
            case .invalidPort(let p): return "ポート「\(p)」が使えません（1〜65535 の数。通信先は、この Mac の 127.0.0.1 だけ）"
            }
        }
    }

    /// `apple`・`ollama:<モデル>`（モデル名の中の `:` は、そのまま：`ollama:qwen3.5:4b`）・`openai:<モデル>@<ポート>`。
    public static func parse(_ text: String) throws -> Engine {
        if text == "apple" { return .apple }
        if text.hasPrefix("ollama:") { return .ollama(model: try validModel(String(text.dropFirst("ollama:".count)))) }
        if text.hasPrefix("openai:") {
            let rest = String(text.dropFirst("openai:".count))
            // ポートは、最後の `@` のあと（ホストは、書けない：127.0.0.1 に固定）
            guard let at = rest.lastIndex(of: "@") else { throw ParseError.invalidPort("") }
            let portText = String(rest[rest.index(after: at)...])
            guard let port = Int(portText), (1...65535).contains(port) else { throw ParseError.invalidPort(portText) }
            return .openAI(model: try validModel(String(rest[..<at])), port: port)
        }
        throw ParseError.unknown(text)
    }

    private static func validModel(_ model: String) throws -> String {
        guard model.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,100}$", options: .regularExpression) != nil else { throw ParseError.invalidModel(model) }
        // Ollama などには、クラウドで動くモデル（名前に cloud が付く）がある。入力を外へ出さないので、ローカルのモデルだけ
        guard !model.lowercased().contains("cloud") else { throw ParseError.cloudModel(model) }
        return model
    }

    /// 通信のアダプター。`apple` は、`FoundationModels` が道具を呼ぶ流れを持つので、ない（`SkillAgent`）。
    func makeChat() -> (any ChatModel)? {
        switch self {
        case .apple: return nil
        case .ollama(let model): return OllamaChat(model: model)
        case .openAI(let model, let port): return OpenAICompatibleChat(model: model, port: port)
        }
    }

    /// 使える状態か（`vc doctor`）：サーバーが動いていて、モデルがあるか。`apple` は、ここでは調べない（`AppleIntelligence`）。失敗は `ChatError`（`description` が、理由と手順）。
    public func verify() async throws {
        try await makeChat()?.check()
    }
}

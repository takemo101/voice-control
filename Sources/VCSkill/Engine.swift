import VCCore
import Foundation

/// スキルを実行するモデル。既定は、Apple のオンデバイスの言語モデル。ほかは、この Mac のローカルのサーバー（`127.0.0.1`）のモデルに替えられる。
/// スキルを選ぶ Tiny-Jev は、どれでも同じ。
public enum Engine: Sendable, Equatable {
    case apple
    /// Ollama のモデル名（例：`qwen3.5:4b`）と、場所（省略すると、この Mac の `127.0.0.1:11434`。同じ LAN の Ollama も、書ける）。
    case ollama(model: String, server: ServerAddress)
    /// OpenAI 互換のサーバー（LM Studio・oMLX・Strata・llama.cpp のサーバー・vLLM・Jan など）のモデルと、場所（この Mac、または**同じ LAN**。`ServerAddress`）。
    case openAI(model: String, server: ServerAddress)

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case invalidModel(String)
        case cloudModel(String)
        case invalidPort(String)
        case invalidHost(String)
        public var description: String {
            switch self {
            case .unknown(let s): return tr("エンジン「\(s)」は使えません（apple・ollama:<モデル>・openai:<モデル>@<ポート>。LAN は openai:<モデル>@<ホスト>:<ポート>。例：ollama:qwen3.5:4b・openai:qwen3-4b@1234）")
            case .invalidModel(let m): return tr("モデル名「\(m)」が使えません（英数字・. _ : / - だけ）")
            case .cloudModel(let m): return tr("「\(m)」は、クラウドのモデルです。音声・画面の内容を、外へ出さないので、使えません")
            case .invalidPort(let p): return tr("ポート「\(p)」が使えません（1〜65535 の数）")
            case .invalidHost(let h): return tr("ホスト「\(h)」は使えません（この Mac と、同じ LAN だけ：127.0.0.1・192.168.x.x などの私的なアドレス・〜.local の名前。インターネットのサーバーは、使えません）")
            }
        }
    }

    /// 既定の Ollama の場所。
    public static let ollamaDefault = ServerAddress.loopback(port: 11434)

    /// `apple`・`ollama:<モデル>`（モデル名の中の `:` は、そのまま：`ollama:qwen3.5:4b`。場所を省くと、`127.0.0.1:11434`）・`ollama:<モデル>@<場所>`・
    /// `openai:<モデル>@<ポート>`（この Mac）・`openai:<モデル>@<ホスト>:<ポート>`（同じ LAN）。場所は、`<ポート>` か `<ホスト>:<ポート>`（`ServerAddress`）。
    public static func parse(_ text: String) throws -> Engine {
        if text == "apple" { return .apple }
        if text.hasPrefix("ollama:") {
            let rest = String(text.dropFirst("ollama:".count))
            guard let at = rest.lastIndex(of: "@") else { return .ollama(model: try validModel(rest), server: ollamaDefault) }   // 場所を省く：既定
            let model = try validModel(String(rest[..<at]))
            return .ollama(model: model, server: try place(String(rest[rest.index(after: at)...])))
        }
        if text.hasPrefix("openai:") {
            let rest = String(text.dropFirst("openai:".count))
            // 場所は、最後の `@` のあと：`<ポート>`（この Mac）か `<ホスト>:<ポート>`（ホストは、この Mac と LAN だけ：`ServerAddress`）
            guard let at = rest.lastIndex(of: "@") else { throw ParseError.invalidPort("") }
            let model = try validModel(String(rest[..<at]))
            return .openAI(model: model, server: try place(String(rest[rest.index(after: at)...])))
        }
        throw ParseError.unknown(text)
    }

    /// 場所（`<ポート>` か `<ホスト>:<ポート>`）。
    private static func place(_ text: String) throws -> ServerAddress {
        let hostText: String?, portText: String
        if let colon = text.lastIndex(of: ":") { hostText = String(text[..<colon]); portText = String(text[text.index(after: colon)...]) } else { hostText = nil; portText = text }
        guard let port = Int(portText), (1...65535).contains(port) else { throw ParseError.invalidPort(portText) }
        guard let hostText else { return .loopback(port: port) }
        do { return try ServerAddress.make(host: hostText, port: port) } catch { throw ParseError.invalidHost(hostText) }
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
        case .ollama(let model, let server): return OllamaChat(model: model, server: server)
        case .openAI(let model, let server): return OpenAICompatibleChat(model: model, server: server)
        }
    }

    /// 使える状態か（`vc doctor`）：サーバーが動いていて、モデルがあるか。`apple` は、ここでは調べない（`AppleIntelligence`）。失敗は `ChatError`（`description` が、理由と手順）。
    /// 通信先が、この Mac の外（同じ LAN）か。**音声・画面の内容が、LAN へ出る**（暗号化されない）。
    public var talksOverLAN: Bool { server.map { !$0.isLoopback } ?? false }

    /// 通信先（`ホスト:ポート`）。Ollama・OpenAI 互換だけ。APIキーの保管庫の鍵。
    public var serverEndpoint: String? { server?.endpoint }

    /// 通信先の場所（Apple は、なし）。
    public var server: ServerAddress? {
        switch self {
        case .apple: return nil
        case let .ollama(_, server), let .openAI(_, server): return server
        }
    }

    public func verify() async throws {
        try await makeChat()?.check()
    }
}

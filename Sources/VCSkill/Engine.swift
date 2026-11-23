import VCCore
import Foundation

/// スキルを実行するモデル。既定は、Apple のオンデバイスの言語モデル。ほかは、モデルのサーバー（Ollama・OpenAI 互換。この Mac の `127.0.0.1` か、**同じ LAN**。`ModelServerKind`・`ServerAddress`）のモデルに替えられる。
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
        case invalidPath(String)
        case invalidScheme(String)
        public var description: String {
            switch self {
            case .unknown(let s): return tr("エンジン「\(s)」は使えません（apple・ollama:<モデル>・openai:<モデル>@<ポート>。LAN は openai:<モデル>@<ホスト>:<ポート>。例：ollama:qwen3.5:4b・openai:qwen3-4b@1234）")
            case .invalidModel(let m): return tr("モデル名「\(m)」が使えません（英数字・. _ : / - だけ）")
            case .cloudModel(let m): return tr("「\(m)」は、クラウドのモデルです。音声・画面の内容を、外へ出さないので、使えません")
            case .invalidPort(let p): return tr("ポート「\(p)」が使えません（1〜65535 の数）")
            case .invalidPath(let p): return tr("経路「\(p)」が使えません（/v1・/v2・/openai/v1 のような、英数字・. _ ~ - の部分を / でつないだもの）")
            case .invalidScheme(let s): return tr("\(s):// は使えません（http:// だけ。暗号化された通信には、未対応です）")
            case .invalidHost(let h): return tr("ホスト「\(h)」は使えません（この Mac と、同じ LAN だけ：127.0.0.1・192.168.x.x などの私的なアドレス・〜.local の名前。インターネットのサーバーは、使えません）")
            }
        }
    }

    /// `apple`・`ollama:<モデル>`（モデル名の中の `:` は、そのまま：`ollama:qwen3.5:4b`。場所を省くと、`127.0.0.1:11434`）・`ollama:<モデル>@<場所>`・
    /// `openai:<モデル>@<ポート>`（この Mac）・`openai:<モデル>@<ホスト>:<ポート>`（同じ LAN）。場所は、`[http://]<ポート>`・`[http://]<ホスト>:<ポート>` のあとに、経路（`EndpointText`・`ServerAddress`）。
    public static func parse(_ text: String) throws -> Engine {
        if text == "apple" { return .apple }
        guard let kind = ModelServerKind.allCases.first(where: { text.hasPrefix($0.prefix) }) else { throw ParseError.unknown(text) }
        let rest = String(text.dropFirst(kind.prefix.count))
        let model: String, address: ServerAddress
        if let at = rest.lastIndex(of: "@") {
            model = try validModel(String(rest[..<at]))
            address = try place(String(rest[rest.index(after: at)...]))
        } else if let fallback = kind.defaultAddress {
            model = try validModel(rest)   // 場所を省く：既定
            address = fallback
        } else {
            throw ParseError.invalidPort("")   // 既定の場所がない種類（OpenAI 互換）：場所が要る
        }
        return kind == .ollama ? .ollama(model: model, server: address) : .openAI(model: model, server: address)
    }

    /// 場所：`[http://]<ポート>`・`[http://]<ホスト>:<ポート>`（あとに経路）。`http://` を付けたときは、ポートを省ける（80）。`http` 以外のスキームは、使えない。
    private static func place(_ raw: String) throws -> ServerAddress {
        let parts = EndpointText.parts(raw)
        if let scheme = parts.scheme, scheme != "http" { throw ParseError.invalidScheme(scheme) }
        guard parts.path.isEmpty || ServerAddress.validBasePath(parts.path) else { throw ParseError.invalidPath(parts.path) }
        let hostText: String?, portText: String
        if let colon = parts.authority.lastIndex(of: ":") { hostText = String(parts.authority[..<colon]); portText = String(parts.authority[parts.authority.index(after: colon)...]) }
        else if parts.scheme != nil { hostText = parts.authority; portText = "80" } else { hostText = nil; portText = parts.authority }
        guard let port = Int(portText), (1...65535).contains(port) else { throw ParseError.invalidPort(portText) }
        guard let hostText else { return .loopback(port: port, basePath: parts.path) }
        do { return try ServerAddress.make(host: hostText, port: port, basePath: parts.path) } catch { throw ParseError.invalidHost(hostText) }
    }

    /// 画面に出すモデルの名前として、使えるか（書き方・クラウドのモデルでない）。
    public static func isUsableModelName(_ name: String) -> Bool { (try? validModel(name)) != nil }   // try?: 使えるか否かだけ（理由は、`parse` が出す）

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

    /// 種類（Apple は、なし）。
    public var kind: ModelServerKind? {
        switch self {
        case .apple: return nil
        case .ollama: return .ollama
        case .openAI: return .openAI
        }
    }

    /// 通信先の場所（Apple は、なし）。
    public var server: ServerAddress? {
        switch self {
        case .apple: return nil
        case let .ollama(_, server), let .openAI(_, server): return server
        }
    }

    /// 使える状態か（`vc doctor`）：サーバーが動いていて、モデルがあるか。`apple` は、ここでは調べない（`AppleIntelligence`）。失敗は `ChatError`（`description` が、理由と直し方）。
    public func verify() async throws {
        try await makeChat()?.check()
    }
}

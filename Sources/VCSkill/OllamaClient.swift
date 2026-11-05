import Foundation

/// Ollama への、1 回の問い合わせの、やりとり（`/api/chat` の message）。
struct OllamaMessage: Codable, Sendable, Equatable {
    var role: String
    var content: String = ""
    var tool_calls: [ToolCall]?
    var tool_name: String?

    struct ToolCall: Codable, Sendable, Equatable {
        var function: Function
        struct Function: Codable, Sendable, Equatable {
            var name: String
            var arguments: [String: String]
            init(name: String, arguments: [String: String]) { self.name = name; self.arguments = arguments }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                // 引数の値は、文字・数・真偽が来うる：文字にそろえる（`command` は文字）
                let raw = (try? c.decode([String: Lenient].self, forKey: .arguments)) ?? [:]   // try?: 引数が読めなければ、空（呼び出し側が、「command がない」と、モデルへ返す）
                arguments = raw.mapValues(\.text)
            }
            private enum CodingKeys: String, CodingKey { case name, arguments }
        }
    }

    /// JSON の、文字・数・真偽を、文字として読む。
    private struct Lenient: Decodable {
        let text: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { text = s }          // try?: 型を順に試す
            else if let i = try? c.decode(Int.self) { text = String(i) }
            else if let d = try? c.decode(Double.self) { text = String(d) }
            else if let b = try? c.decode(Bool.self) { text = String(b) }
            else { text = "" }
        }
    }
}

public enum OllamaError: Error, Equatable, CustomStringConvertible {
    /// Ollama に接続できない（起動していない）。
    case notRunning
    case modelNotFound(String)
    case http(Int, String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .notRunning: return "Ollama に接続できません（\(OllamaClient.host)）。Ollama を起動してください"
        case .modelNotFound(let m): return "Ollama に、モデル「\(m)」がありません。ollama pull \(m) で取得してください"
        case .http(let status, let body): return "Ollama がエラーを返しました（HTTP \(status)）：\(body.prefix(200))"
        case .badResponse(let why): return "Ollama の応答を読めません（\(why)）"
        }
    }
}

public extension Engine {
    /// 使える状態か（`vc doctor`）：`ollama:` なら、Ollama が動いていて、そのモデルがあるか。`apple` は、ここでは調べない（`AppleIntelligence`）。失敗は `OllamaError`。
    func verify() async throws {
        if case .ollama(let model) = self { try await OllamaClient.check(model: model) }
    }
}

/// モデルとの 1 回のやりとり。テストで、偽物に替える。
protocol OllamaChatting: Sendable {
    func chat(model: String, messages: [OllamaMessage]) async throws -> OllamaMessage
}

/// この Mac の Ollama（`127.0.0.1:11434`）と話す。**通信先は、この 1 か所に固定**（環境変数・設定で、替えられない：音声・画面の内容が、外へ出ない）。
struct OllamaClient: OllamaChatting {
    static let host = "127.0.0.1:11434"
    static let live = OllamaClient()

    /// `run_command` という道具 1 つ。**説明に、特定のコマンドの例を入れない**：例（`agent-desktop snapshot -i`・`open -a Spotify`）があると、qwen3.5:4b が、スキルの手順より例に引きずられた（クリップボードの英訳が 0/4 → 例を除くと 4/4。測定）。
    private static let tools: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": "run_command",
            "description": "Run one shell-free command line and get its exit code and output.",
            "parameters": ["type": "object", "properties": ["command": ["type": "string", "description": "the full command line"]], "required": ["command"]],
        ],
    ]]

    func chat(model: String, messages: [OllamaMessage]) async throws -> OllamaMessage {
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "tools": Self.tools,
            "options": ["temperature": 0.2, "num_ctx": 8192],
            "messages": try messages.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
        ]
        let (data, status) = try await send(path: "/api/chat", body: body)
        if status == 404 { throw OllamaError.modelNotFound(model) }
        guard status == 200 else { throw OllamaError.http(status, String(decoding: data, as: UTF8.self)) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let message = root["message"] else { throw OllamaError.badResponse("message がない") }   // try?: 読めなければ、下の失敗として返す
        do { return try JSONDecoder().decode(OllamaMessage.self, from: JSONSerialization.data(withJSONObject: message)) } catch { throw OllamaError.badResponse("\(error)") }
    }

    /// 動いているか・モデルがあるか（`vc doctor`）。
    static func check(model: String) async throws {
        let (data, status) = try await live.send(path: "/api/tags", body: nil)
        guard status == 200, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let models = root["models"] as? [[String: Any]] else { throw OllamaError.http(status, String(decoding: data, as: UTF8.self)) }   // try?: 読めなければ、失敗として返す
        let names = models.compactMap { $0["name"] as? String }
        // 「qwen3.5」と書けば「qwen3.5:latest」を指す（Ollama と同じ）
        let wanted = model.contains(":") ? model : model + ":latest"
        guard names.contains(wanted) else { throw OllamaError.modelNotFound(model) }
    }

    private func send(path: String, body: [String: Any]?) async throws -> (Data, Int) {
        guard let url = URL(string: "http://\(Self.host)\(path)") else { throw OllamaError.badResponse("URL") }
        var request = URLRequest(url: url, timeoutInterval: 180)   // 初回は、モデルの読み込みで、長い
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost || error.code == .cannotFindHost {
            throw OllamaError.notRunning
        }
    }
}

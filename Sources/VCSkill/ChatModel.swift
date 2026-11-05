import Foundation

/// スキルを実行するモデルとの、やりとり 1 回分の文（どのモデルの通信にも共通の形）。通信の形（Ollama・OpenAI 互換）への変換は、各アダプターが持つ。
struct ChatMessage: Sendable, Equatable {
    enum Role: String, Sendable { case system, user, assistant, tool }

    /// モデルが求めた道具の呼び出し。`id` は、OpenAI 互換が、結果と結びつけるのに使う（Ollama は付けない）。
    struct ToolCall: Sendable, Equatable {
        var id: String?
        var name: String
        var arguments: [String: String]
    }

    var role: Role
    var content: String = ""
    var toolCalls: [ToolCall] = []
    /// `role == .tool`：どの呼び出しの結果か（`id`・`name` を、そのまま返す）。
    var toolCallID: String?
    var toolName: String?
}

/// スキルを実行するモデルの、通信のアダプター。道具を呼ぶ流れ（呼ぶ → 結果を返す → 繰り返す）は、`ToolLoopAgent` が持つ（どのアダプターでも同じ）。
/// **通信先は、この Mac の `127.0.0.1` だけ**（`LocalServer`）。
protocol ChatModel: Sendable {
    /// これまでのやりとりを渡して、モデルの次の発言（文、または道具の呼び出し）を受け取る。
    func chat(_ messages: [ChatMessage]) async throws -> ChatMessage
    /// 使える状態か（`vc doctor`）：サーバーが動いていて、モデルがあるか。失敗は `ChatError`。
    func check() async throws
}

extension ChatModel {
    func check() async throws {}
}

enum ChatError: Error, Equatable, CustomStringConvertible {
    /// サーバーに接続できない（起動していない）。
    case notRunning(server: String, endpoint: String)
    case modelNotFound(model: String, hint: String)
    case http(Int, String)
    case badResponse(String)

    var description: String {
        switch self {
        case .notRunning(let server, let endpoint): return "\(server) に接続できません（\(endpoint)）。起動してください"
        case .modelNotFound(let model, let hint): return "モデル「\(model)」がありません。\(hint)"
        case .http(let status, let body): return "モデルのサーバーがエラーを返しました（HTTP \(status)）：\(body.prefix(200))"
        case .badResponse(let why): return "モデルのサーバーの応答を読めません（\(why)）"
        }
    }
}

/// `run_command` という道具 1 つ（どのアダプターにも共通）。**説明に、特定のコマンドの例を入れない**：例（`agent-desktop snapshot -i`・`open -a Spotify`）があると、qwen3.5:4b が、スキルの手順より例に引きずられた（クリップボードの英訳が 0/4 → 例を除くと 4/4。測定）。
enum ChatTools {
    static let runCommand: [String: Any] = [
        "type": "function",
        "function": [
            "name": "run_command",
            "description": "Run one shell-free command line and get its exit code and output.",
            "parameters": ["type": "object", "properties": ["command": ["type": "string", "description": "the full command line"]], "required": ["command"]],
        ],
    ]
}

/// この Mac の `127.0.0.1:<ポート>` の HTTP サーバー。**通信先は、ここに固定**（ホスト名を、設定・環境変数・引数で、替えられない：音声・画面の内容が、外へ出ない）。
struct LocalServer: Sendable, Equatable {
    /// 表示用の名前（`Ollama` など）。
    let name: String
    let port: Int
    var endpoint: String { "127.0.0.1:\(port)" }

    /// JSON を送る（`body` があれば POST、なければ GET）。状態コードと本文を返す。接続できなければ `ChatError.notRunning`。
    func send(path: String, body: [String: Any]?) async throws -> (data: Data, status: Int) {
        guard let url = URL(string: "http://\(endpoint)\(path)") else { throw ChatError.badResponse("URL") }
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
            throw ChatError.notRunning(server: name, endpoint: endpoint)
        }
    }
}

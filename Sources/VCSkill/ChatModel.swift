import Foundation
import VCCore

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
/// **通信先は、この Mac と、同じ LAN の中だけ**（`LocalServer`・`ServerAddress`）。
protocol ChatModel: Sendable {
    /// これまでのやりとりを渡して、モデルの次の発言（文、または道具の呼び出し）を受け取る。
    /// `tools`：`run_command` の道具を渡すか。**文だけがほしいとき（依頼を分けるとき）は、false**（道具があると、小さなモデルは、文でなく、道具を呼んで返す）。
    func chat(_ messages: [ChatMessage], tools: Bool) async throws -> ChatMessage
    /// 使える状態か（`vc doctor`）：サーバーが動いていて、モデルがあるか。失敗は `ChatError`。
    func check() async throws
}

extension ChatModel {
    func check() async throws {}
    /// スキルの実行：道具つき。
    func chat(_ messages: [ChatMessage]) async throws -> ChatMessage { try await chat(messages, tools: true) }
}

enum ChatError: Error, Equatable, CustomStringConvertible {
    /// サーバーに接続できない（起動していない）。
    case notRunning(server: String, endpoint: String)
    case modelNotFound(model: String, hint: String)
    case http(Int, String)
    case badResponse(String)
    /// APIキーが、違う・要る（HTTP 401・403）。
    case unauthorized(server: String, endpoint: String)
    /// 時間内に、応答が終わらない。
    case timedOut(server: String, endpoint: String)
    /// `.local` の名前が、引けない。
    case unresolved(host: String)
    /// 名前の引き先が、私的なアドレスでない（外を指している）：送らない。
    case notPrivate(host: String, answer: String)

    var description: String {
        switch self {
        case .notRunning(let server, let endpoint): return tr("\(server) に接続できません（\(endpoint)）。起動してください")
        case .modelNotFound(let model, let hint): return tr("モデル「\(model)」がありません。\(hint)")
        case .http(let status, let body): return tr("モデルのサーバーがエラーを返しました（HTTP \(status)）：\(body.prefix(200))")
        case .badResponse(let why): return tr("モデルのサーバーの応答を読めません（\(why)）")
        case .unauthorized(let server, let endpoint): return tr("\(server)（\(endpoint)）が、APIキーを受け付けません。キーが違うか、必要です（設定 > モデル > APIキー）")
        case .timedOut(let server, let endpoint): return tr("\(server)（\(endpoint)）が、時間内に応えませんでした。届いているか・起動しているかを、確かめてください")
        case .unresolved(let host): return tr("「\(host)」の場所を、引けません")
        case .notPrivate(let host, let answer): return tr("「\(host)」の引き先（\(answer)）が、この Mac・LAN の外です。送りません")
        }
    }
}

/// `run_command` という道具 1 つ（どのアダプターにも共通）。**説明に、特定のコマンドの例を入れない**：例（`agent-desktop snapshot -i`・`open -a Spotify`）があると、qwen3.5:4b が、スキルの手順より例に引きずられた（クリップボードの英訳が 0/4 → 例を除くと 4/4。測定）。
enum ChatTools {
    /// 呼ぶたびに作る（`[String: Any]` は Sendable でない：グローバルに持たない）。
    static var runCommand: [String: Any] { [
        "type": "function",
        "function": [
            "name": "run_command",
            "description": "Run one shell-free command line and get its exit code and output.",
            "parameters": ["type": "object", "properties": ["command": ["type": "string", "description": "the full command line"]], "required": ["command"]],
        ],
    ] }
}

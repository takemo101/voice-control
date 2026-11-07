import Foundation

/// Ollama（`127.0.0.1:11434`。`/api/chat`）のアダプター。
struct OllamaChat: ChatModel {
    static let port = 11434
    let model: String
    let server = LocalServer(name: "Ollama", port: Self.port)

    func chat(_ messages: [ChatMessage], tools: Bool) async throws -> ChatMessage {
        let (data, status) = try await server.send(path: "/api/chat", body: Self.request(model: model, messages: messages, tools: tools))
        if status == 404 { throw ChatError.modelNotFound(model: model, hint: "ollama pull \(model) で取得してください") }
        guard status == 200 else { throw ChatError.http(status, String(decoding: data, as: UTF8.self)) }
        return try Self.reply(from: data)
    }

    func check() async throws {
        let (data, status) = try await server.send(path: "/api/tags", body: nil)
        guard status == 200, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let models = root["models"] as? [[String: Any]] else { throw ChatError.http(status, String(decoding: data, as: UTF8.self)) }   // try?: 読めなければ、失敗として返す
        // 「qwen3.5」と書けば「qwen3.5:latest」を指す（Ollama と同じ）
        let wanted = model.contains(":") ? model : model + ":latest"
        guard models.compactMap({ $0["name"] as? String }).contains(wanted) else { throw ChatError.modelNotFound(model: model, hint: "ollama pull \(model) で取得してください") }
    }

    // MARK: 通信の形（Ollama）

    /// `think: false`：考える部分を出させない（遅くなる）。
    static func request(model: String, messages: [ChatMessage], tools: Bool = true) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "stream": false, "think": false,
            "options": ["temperature": tools ? 0.2 : 0.0, "num_ctx": 8192],
            "messages": messages.map(wire),
        ]
        if tools { body["tools"] = [ChatTools.runCommand] }
        return body
    }

    private static func wire(_ m: ChatMessage) -> [String: Any] {
        var out: [String: Any] = ["role": m.role.rawValue, "content": m.content]
        if !m.toolCalls.isEmpty { out["tool_calls"] = m.toolCalls.map { ["function": ["name": $0.name, "arguments": $0.arguments]] } }
        if let name = m.toolName { out["tool_name"] = name }
        return out
    }

    static func reply(from data: Data) throws -> ChatMessage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let message = root["message"] as? [String: Any] else { throw ChatError.badResponse("message がない") }   // try?: 読めなければ、下の失敗として返す
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> ChatMessage.ToolCall? in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            return ChatMessage.ToolCall(id: call["id"] as? String, name: name, arguments: ArgumentText.strings(function["arguments"] as? [String: Any] ?? [:]))
        }
        return ChatMessage(role: .assistant, content: message["content"] as? String ?? "", toolCalls: calls)
    }
}

/// 道具の引数（JSON）の値を、文字にそろえる（文字・数・真偽が来うる。`command` は文字）。
enum ArgumentText {
    static func strings(_ arguments: [String: Any]) -> [String: String] {
        arguments.compactMapValues { value in
            switch value {
            case let s as String: return s
            case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
            default: return nil
            }
        }
    }
}

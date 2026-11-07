import Foundation

/// OpenAI 互換の API（`/v1/chat/completions`。道具の呼び出しつき）のアダプター。LM Studio・llama.cpp のサーバー・vLLM・Jan など。**通信先は、この Mac の `127.0.0.1:<ポート>` だけ**。
struct OpenAICompatibleChat: ChatModel {
    let model: String
    let server: LocalServer

    init(model: String, port: Int) {
        self.model = model
        server = LocalServer(name: "OpenAI 互換サーバー", port: port)
    }

    func chat(_ messages: [ChatMessage], tools: Bool) async throws -> ChatMessage {
        let (data, status) = try await server.send(path: "/v1/chat/completions", body: Self.request(model: model, messages: messages, tools: tools))
        if status == 404 { throw ChatError.modelNotFound(model: model, hint: "サーバーに、このモデルを読み込んでください") }
        guard status == 200 else { throw ChatError.http(status, String(decoding: data, as: UTF8.self)) }
        return try Self.reply(from: data)
    }

    func check() async throws {
        let (data, status) = try await server.send(path: "/v1/models", body: nil)
        guard status == 200, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let models = root["data"] as? [[String: Any]] else { throw ChatError.http(status, String(decoding: data, as: UTF8.self)) }   // try?: 読めなければ、失敗として返す
        guard models.compactMap({ $0["id"] as? String }).contains(model) else { throw ChatError.modelNotFound(model: model, hint: "サーバーに、このモデルを読み込んでください") }
    }

    // MARK: 通信の形（OpenAI 互換）

    /// `reasoning_effort: none`：考える部分を出させない（測定：Ollama の `/v1` で、qwen3.5:4b の短い依頼が 88.7 秒 → 5.1 秒）。考えないモデルは、無視する。
    static func request(model: String, messages: [ChatMessage], tools: Bool = true) -> [String: Any] {
        var body: [String: Any] = ["model": model, "stream": false, "temperature": tools ? 0.2 : 0.0, "reasoning_effort": "none", "messages": messages.map(wire)]
        if tools { body["tools"] = [ChatTools.runCommand] }
        return body
    }

    private static func wire(_ m: ChatMessage) -> [String: Any] {
        var out: [String: Any] = ["role": m.role.rawValue, "content": m.content]
        if !m.toolCalls.isEmpty {
            // 道具の引数は、JSON の文字列で渡す（この API の形）
            out["tool_calls"] = m.toolCalls.map { call -> [String: Any] in
                let arguments = (try? JSONSerialization.data(withJSONObject: call.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"   // try?: 文字だけの辞書は、変換できる（できなければ、空の引数。呼び出し側が、「command がない」と返す）
                return ["id": call.id ?? "call_\(call.name)", "type": "function", "function": ["name": call.name, "arguments": arguments]]
            }
        }
        if m.role == .tool { out["tool_call_id"] = m.toolCallID ?? "call_\(m.toolName ?? "run_command")" }
        return out
    }

    static func reply(from data: Data) throws -> ChatMessage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],   // try?: 読めなければ、下の失敗として返す
              let message = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { throw ChatError.badResponse("choices[0].message がない") }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> ChatMessage.ToolCall? in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            // 引数は、JSON の文字列（まれに、辞書で来るサーバーもある）
            let object: [String: Any]
            if let text = function["arguments"] as? String { object = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:] }   // try?: 読めなければ、空（「command がない」と、モデルへ返る）
            else { object = function["arguments"] as? [String: Any] ?? [:] }
            return ChatMessage.ToolCall(id: call["id"] as? String, name: name, arguments: ArgumentText.strings(object))
        }
        return ChatMessage(role: .assistant, content: message["content"] as? String ?? "", toolCalls: calls)
    }
}

import Foundation

/// **pi の RPC モード**（`pi --mode rpc`：行ごとの JSON の、命令・応答・出来事）を、**ACP の言葉に訳す**。これで、`ACPChatBackend` が、そのまま、pi と話せる（会話の使い回し・許可の判断・段階・Esc・ファイル・画像・モデル・OS の制限・従来の方式への退避）。
/// 第三者の ACP アダプター（`pi-acp`）は、使わない（個人の作者・方針外）。**pi には、許可の要求の仕組みがない**ので、毎回の確認は、こちらが書く拡張（`PiGateExtension`）が、`write`・`edit`・`bash` の前に、`confirm` を求め、ここで、ACP の許可の要求（`session/request_permission`）に訳す。
/// 対応：
/// - `initialize` → `get_state`（起動の確認）／`session/new` → `new_session`＋モデルの一覧（`get_available_models`・`get_state`）／`session/prompt` → `prompt`（答えは、`agent_settled` で、終わる）／`session/cancel` → `abort`／`session/set_model` → `set_model`。
/// - 出来事：`text_delta` → `agent_message_chunk`／考え中 → `agent_thought_chunk`（進みの目印）／`tool_execution_*` → `tool_call`・`tool_call_update`／拡張の `confirm` → `session/request_permission`。
/// `@unchecked Sendable`：可変の持ち物は、すべて、ロックの下。
final class PiRPCDialect: ACPWireDialect, @unchecked Sendable {
    private enum Step {
        case initialize(JSONValue)
        case newSession(JSONValue)
        case models(JSONValue)
        case state(JSONValue, models: [JSONValue])
        case prompt(JSONValue)
        case setModel(JSONValue)
        case ignore
    }

    private let lock = NSLock()
    // — ここから `lock` の下 —
    private var steps: [String: Step] = [:]
    private var counter = 0
    private var sessionNumber = 0
    private var sessionID = "pi-0"
    private var promptID: JSONValue?
    private var sawText = false
    private var failure: String?
    // — ここまで —

    // MARK: ACP → pi

    func outgoing(_ message: JSONValue) -> ACPWireOutput {
        guard let method = message["method"]?.string else { return answerToExtension(message) }   // 方法がない：相手からの要求（許可の確認）への、応答
        let id = message["id"]
        let params = message["params"] ?? .null
        switch method {
        case "initialize":
            guard let id else { return .init() }
            return send("get_state", [:], .initialize(id))
        case "session/new":
            guard let id else { return .init() }
            return send("new_session", [:], .newSession(id))
        case "session/prompt":
            guard let id else { return .init() }
            return prompt(id: id, params: params)
        case "session/cancel":
            return send("abort", [:], .ignore)
        case "session/set_model":
            guard let id, let model = params["modelId"]?.string, let slash = model.firstIndex(of: "/") else { return id.map { fail($0, "unknown model") } ?? .init() }
            return send("set_model", ["provider": .string(String(model[..<slash])), "modelId": .string(String(model[model.index(after: slash)...]))], .setModel(id))
        case "session/close", "session/set_mode", "session/set_config_option":
            return id.map { reply($0, .object([:])) } ?? .init()
        default:
            return id.map { fail($0, "method not found: \(method)") } ?? .init()
        }
    }

    private func prompt(id: JSONValue, params: JSONValue) -> ACPWireOutput {
        var texts: [String] = []
        var images: [JSONValue] = []
        for block in params["prompt"]?.array ?? [] {
            switch block["type"]?.string {
            case "text": if let text = block["text"]?.string { texts.append(text) }
            case "image": if let data = block["data"]?.string { images.append(.object(["type": .string("image"), "data": .string(data), "mimeType": .string(block["mimeType"]?.string ?? "image/png")])) }
            default: break   // `resource_link`：文面の前置きが、作業フォルダの中の場所を、書いている。埋め込みは、宣言していない（文面に入れて届く）
            }
        }
        lock.withLock { promptID = id; sawText = false; failure = nil }
        var fields: [String: JSONValue] = ["message": .string(texts.joined(separator: "\n\n"))]
        if !images.isEmpty { fields["images"] = .array(images) }
        return send("prompt", fields, .prompt(id))
    }

    /// 許可の要求への、応答 → 拡張の `confirm` への返事。
    private func answerToExtension(_ message: JSONValue) -> ACPWireOutput {
        guard let id = message["id"]?.string else { return .init() }
        var record: [String: JSONValue] = ["type": .string("extension_ui_response"), "id": .string(id)]
        let outcome = message["result"]?["outcome"]
        if outcome?["outcome"]?.string == "selected" { record["confirmed"] = .bool(outcome?["optionId"]?.string == "allow") } else { record["cancelled"] = .bool(true) }
        return ACPWireOutput(lines: [.object(record)])
    }

    // MARK: pi → ACP

    func incoming(_ record: JSONValue) -> ACPWireOutput {
        switch record["type"]?.string {
        case "response": return response(record)
        case "message_update": return messageUpdate(record)
        case "message_end":
            if record["message"]?["role"]?.string == "assistant", record["message"]?["stopReason"]?.string == "error" {
                lock.withLock { failure = record["message"]?["errorMessage"]?.string ?? "error" }
            }
            return .init()
        case "tool_execution_start": return toolStart(record)
        case "tool_execution_end": return toolEnd(record)
        case "extension_ui_request": return extensionRequest(record)
        case "agent_settled": return settled(record)
        default: return .init()
        }
    }

    private func response(_ record: JSONValue) -> ACPWireOutput {
        guard let key = record["id"]?.string, let step = lock.withLock({ steps.removeValue(forKey: key) }) else { return .init() }
        let ok = record["success"]?.bool == true
        let error = record["error"]?.string ?? "error"
        switch step {
        case .ignore: return .init()
        case let .initialize(id):
            return ok ? reply(id, .object(["protocolVersion": .number(1), "agentCapabilities": .object(["promptCapabilities": .object(["image": .bool(true), "embeddedContext": .bool(false)])])])) : fail(id, error)
        case let .newSession(id):
            guard ok else { return fail(id, error) }
            return send("get_available_models", [:], .models(id))
        case let .models(id):
            let models = ok ? (record["data"]?["models"]?.array ?? []) : []   // 一覧が取れなくても、セッションは、作る（モデルを選べないだけ）
            return send("get_state", [:], .state(id, models: models))
        case let .state(id, models):
            let number = lock.withLock { () -> Int in sessionNumber += 1; sessionID = "pi-\(sessionNumber)"; promptID = nil; return sessionNumber }
            let choices = models.compactMap { model -> JSONValue? in
                guard let provider = model["provider"]?.string, let modelID = model["id"]?.string else { return nil }
                return .object(["modelId": .string("\(provider)/\(modelID)"), "name": .string(model["name"]?.string ?? modelID)])
            }
            var result: [String: JSONValue] = ["sessionId": .string("pi-\(number)")]
            if !choices.isEmpty {
                var models: [String: JSONValue] = ["availableModels": .array(choices)]
                if ok, let provider = record["data"]?["model"]?["provider"]?.string, let modelID = record["data"]?["model"]?["id"]?.string { models["currentModelId"] = .string("\(provider)/\(modelID)") }
                result["models"] = .object(models)
            }
            return reply(id, .object(result))
        case let .prompt(id):
            if !ok { lock.withLock { promptID = nil }; return fail(id, error) }
            if record["data"]?["disposition"]?.string == "handled" {   // 拡張などが、受けた：走り出さない（`agent_settled` は、来ない）
                lock.withLock { promptID = nil }
                return reply(id, .object(["stopReason": .string("end_turn")]))
            }
            return .init()
        case let .setModel(id):
            return ok ? reply(id, .object([:])) : fail(id, error)
        }
    }

    private func messageUpdate(_ record: JSONValue) -> ACPWireOutput {
        guard let event = record["assistantMessageEvent"], let type = event["type"]?.string else { return .init() }
        switch type {
        case "text_delta":
            guard let delta = event["delta"]?.string else { return .init() }
            lock.withLock { sawText = true }
            return update(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string(delta)])])
        case "thinking_delta":   // 見せない：進んでいる、という目印（時間切れの判定のため）
            return update(["sessionUpdate": .string("agent_thought_chunk"), "content": .object(["type": .string("text"), "text": .string("")])])
        default: return .init()
        }
    }

    private func toolStart(_ record: JSONValue) -> ACPWireOutput {
        guard let callID = record["toolCallId"]?.string, let name = record["toolName"]?.string else { return .init() }
        var fields = Self.toolCall(name: name, input: record["args"])
        fields["sessionUpdate"] = .string("tool_call"); fields["toolCallId"] = .string(callID); fields["status"] = .string("in_progress")
        return update(fields)
    }

    private func toolEnd(_ record: JSONValue) -> ACPWireOutput {
        guard let callID = record["toolCallId"]?.string, let name = record["toolName"]?.string else { return .init() }
        var fields: [String: JSONValue] = ["sessionUpdate": .string("tool_call_update"), "toolCallId": .string(callID), "status": .string(record["isError"]?.bool == true ? "failed" : "completed")]
        if Self.kind(of: name) == "execute" {   // コマンドの出力（端末の出力の断片と同じ形：`ACPToolOutput`）
            let text = (record["result"]?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined()
            if !text.isEmpty { fields["_meta"] = .object(["terminal_output_delta": .object(["data": .string(text)])]) }
        }
        return update(fields)
    }

    private func extensionRequest(_ record: JSONValue) -> ACPWireOutput {
        guard let id = record["id"]?.string, let method = record["method"]?.string else { return .init() }
        switch method {
        case "confirm":
            // こちらの拡張（題が `vc-gate:`）の確認だけを、許可の要求にする。利用者の別の拡張が出した確認は、こちらの操作ではない：取りやめで返す
            guard let title = record["title"]?.string, title.hasPrefix("vc-gate:") else {
                return ACPWireOutput(lines: [.object(["type": .string("extension_ui_response"), "id": .string(id), "cancelled": .bool(true)])])
            }
            let name = String(title.dropFirst("vc-gate:".count))
            // 拡張が、道具の引数を、JSON の文字にして、`message` に入れて渡す（切らない：コマンドは、全部を見せる）
            let input = record["message"]?.string.flatMap { JSONValue.parse(Data($0.utf8)) }
            let sessionID = lock.withLock { self.sessionID }
            let params: JSONValue = .object([
                "sessionId": .string(sessionID),
                "toolCall": .object(Self.toolCall(name: name, input: input)),
                "options": .array([.object(["kind": .string("allow_once"), "optionId": .string("allow"), "name": .string("Allow")]), .object(["kind": .string("reject_once"), "optionId": .string("reject"), "name": .string("Reject")])])])
            return ACPWireOutput(messages: [.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string("session/request_permission"), "params": params])])
        case "select", "input", "editor":   // こちらの拡張は、使わない：待たせないように、取りやめで答える
            return ACPWireOutput(lines: [.object(["type": .string("extension_ui_response"), "id": .string(id), "cancelled": .bool(true)])])
        default: return .init()   // 状態・題・通知：返事は、要らない
        }
    }

    private func settled(_ record: JSONValue) -> ACPWireOutput {
        let (id, text, failed) = lock.withLock { () -> (JSONValue?, Bool, String?) in
            let taken = (promptID, sawText, failure); promptID = nil; return taken
        }
        guard let id else { return .init() }
        if let failed, !text { return fail(id, failed) }   // 答えが、1 文字も出ないまま、提供元の失敗で終わった：理由を、伝える
        return reply(id, .object(["stopReason": .string(record["aborted"]?.bool == true ? "cancelled" : "end_turn")]))
    }

    // MARK: 道具の呼び出し

    /// pi の道具の名前 → ACP の種類。
    static func kind(of tool: String) -> String {
        switch tool {
        case "read", "grep", "find", "ls": return "read"
        case "write", "edit": return "edit"
        case "bash": return "execute"
        default: return "other"
        }
    }

    /// ACP の `toolCall` の欄（種類・名前・題・引数・場所）。`ACPToolCall` が読む形。
    static func toolCall(name: String, input: JSONValue?) -> [String: JSONValue] {
        let path = input?["path"]?.string
        let command = input?["command"]?.string
        // 題：コマンド・場所があれば、それ。**ほかの道具（拡張・MCP）は、名前と引数**（何を実行するか、確認の文で見えるように。長いものは切る：表示だけ）
        var title = command ?? path ?? name
        if command == nil, path == nil, kind(of: name) == "other", let input, input != .object([:]), let data = input.serialized() {
            title = "\(name) " + String(String(decoding: data, as: UTF8.self).prefix(300))
        }
        var fields: [String: JSONValue] = ["kind": .string(kind(of: name)), "name": .string(name), "title": .string(title)]
        if let command { fields["rawInput"] = .object(["command": .string(command)]) }
        if let path { fields["locations"] = .array([.object(["path": .string(path)])]) }
        return fields
    }

    // MARK: 部品

    private func update(_ fields: [String: JSONValue]) -> ACPWireOutput {
        let sessionID = lock.withLock { self.sessionID }
        return ACPWireOutput(messages: [.object(["jsonrpc": .string("2.0"), "method": .string("session/update"), "params": .object(["sessionId": .string(sessionID), "update": .object(fields)])])])
    }

    private func send(_ type: String, _ fields: [String: JSONValue], _ step: Step) -> ACPWireOutput {
        let key: String = lock.withLock { counter += 1; let key = String(counter); steps[key] = step; return key }
        var record = fields
        record["id"] = .string(key); record["type"] = .string(type)
        return ACPWireOutput(lines: [.object(record)])
    }

    private func reply(_ id: JSONValue, _ result: JSONValue) -> ACPWireOutput {
        ACPWireOutput(messages: [.object(["jsonrpc": .string("2.0"), "id": id, "result": result])])
    }

    private func fail(_ id: JSONValue, _ message: String) -> ACPWireOutput {
        ACPWireOutput(messages: [.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32000), "message": .string(message)])])])
    }
}

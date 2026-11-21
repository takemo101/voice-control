import Foundation
import Testing
@testable import VCSkill

/// pi の RPC モードを、ACP に訳す（`PiRPCDialect`）：訳し方（**純粋**）と、偽の pi（行ごとの JSON を話す Python）を、`ACPChatBackend` につないだ通し。**文は、作り物**。
@Suite struct PiRPCDialectTests {
    private func obj(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue { .object(Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) })) }
    private func request(_ id: Int, _ method: String, _ params: JSONValue = .object([:])) -> JSONValue { obj(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]) }
    private func notification(_ method: String, _ params: JSONValue) -> JSONValue { obj(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]) }
    /// 相手へ書いた 1 行の、`id`（応答に、付ける）。
    private func sentID(_ output: ACPWireOutput) -> String { output.lines.first?["id"]?.string ?? "" }
    private func piResponse(_ id: String, command: String, data: JSONValue = .null, success: Bool = true, error: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "command": .string(command), "success": .bool(success), "data": data]
        if let error { fields["error"] = .string(error) }
        return .object(fields)
    }

    @Test func aNewSessionChainsTheModelListAndAnswersWithTheSessionAndProviderQualifiedModels() {
        let dialect = PiRPCDialect()
        let created = dialect.outgoing(request(7, "session/new"))
        #expect(created.lines.first?["type"]?.string == "new_session" && created.messages.isEmpty)
        let models = dialect.incoming(piResponse(sentID(created), command: "new_session", data: obj(["cancelled": .bool(false)])))
        #expect(models.lines.first?["type"]?.string == "get_available_models")
        let state = dialect.incoming(piResponse(sentID(models), command: "get_available_models", data: obj(["models": .array([
            obj(["provider": .string("p"), "id": .string("fast"), "name": .string("Fast")]), obj(["provider": .string("q"), "id": .string("deep")])])])))
        #expect(state.lines.first?["type"]?.string == "get_state")
        let done = dialect.incoming(piResponse(sentID(state), command: "get_state", data: obj(["model": obj(["provider": .string("p"), "id": .string("fast")])])))
        let result = done.messages.first?["result"]
        #expect(done.messages.first?["id"] == .number(7) && result?["sessionId"]?.string == "pi-1")
        #expect(result?["models"]?["availableModels"]?.array?.compactMap { $0["modelId"]?.string } == ["p/fast", "q/deep"] && result?["models"]?["currentModelId"]?.string == "p/fast")
        // 一覧が取れなくても、セッションは、作る（モデルを選べないだけ）
        let again = dialect.outgoing(request(8, "session/new"))
        let noModels = dialect.incoming(piResponse(sentID(again), command: "new_session"))
        let failedList = dialect.incoming(piResponse(sentID(noModels), command: "get_available_models", success: false, error: "x"))
        let bare = dialect.incoming(piResponse(sentID(failedList), command: "get_state", data: .object([:])))
        #expect(bare.messages.first?["result"]?["sessionId"]?.string == "pi-2" && bare.messages.first?["result"]?["models"] == nil)
    }

    @Test func aPromptCarriesTheTextAndImagesAndLeavesOutLinksAndTheTurnEndsWhenPiSettles() {
        let dialect = PiRPCDialect()
        let blocks: JSONValue = .array([
            obj(["type": .string("resource_link"), "uri": .string("file:///x"), "name": .string("x")]),
            obj(["type": .string("image"), "data": .string("QUJD"), "mimeType": .string("image/png")]),
            obj(["type": .string("text"), "text": .string("こんにちは")])])
        let sent = dialect.outgoing(request(3, "session/prompt", obj(["sessionId": .string("pi-1"), "prompt": blocks])))
        #expect(sent.lines.first?["type"]?.string == "prompt" && sent.lines.first?["message"]?.string == "こんにちは")
        #expect(sent.lines.first?["images"]?.array?.first?["data"]?.string == "QUJD")
        // 受理されただけでは、終わらない。少しずつの文字は、通知になる
        #expect(dialect.incoming(piResponse(sentID(sent), command: "prompt", data: obj(["disposition": .string("started")]))).messages.isEmpty)
        let chunk = dialect.incoming(obj(["type": .string("message_update"), "assistantMessageEvent": obj(["type": .string("text_delta"), "delta": .string("答え")])]))
        #expect(chunk.messages.first?["params"]?["update"]?["sessionUpdate"]?.string == "agent_message_chunk" && chunk.messages.first?["params"]?["update"]?["content"]?["text"]?.string == "答え")
        let end = dialect.incoming(obj(["type": .string("agent_settled"), "aborted": .bool(false)]))
        #expect(end.messages.first?["id"] == .number(3) && end.messages.first?["result"]?["stopReason"]?.string == "end_turn")
        #expect(dialect.incoming(obj(["type": .string("agent_settled"), "aborted": .bool(false)])).messages.isEmpty)   // 二重には、終わらない
    }

    @Test func anAbortedTurnEndsAsCancelledAndAProviderFailureWithoutTextBecomesAnError() {
        let dialect = PiRPCDialect()
        _ = dialect.outgoing(request(1, "session/prompt", obj(["prompt": .array([obj(["type": .string("text"), "text": .string("q")])])])))
        let cancelled = dialect.incoming(obj(["type": .string("agent_settled"), "aborted": .bool(true)]))
        #expect(cancelled.messages.first?["result"]?["stopReason"]?.string == "cancelled")
        _ = dialect.outgoing(request(2, "session/prompt", obj(["prompt": .array([obj(["type": .string("text"), "text": .string("q")])])])))
        _ = dialect.incoming(obj(["type": .string("message_end"), "message": obj(["role": .string("assistant"), "stopReason": .string("error"), "errorMessage": .string("quota exceeded")])]))
        let failed = dialect.incoming(obj(["type": .string("agent_settled"), "aborted": .bool(false)]))
        #expect(failed.messages.first?["error"]?["message"]?.string == "quota exceeded")     // 答えが、1 文字も出ないまま：理由を伝える
    }

    @Test func theGatesConfirmBecomesAPermissionRequestWithTheRealCommandAndTheAnswerGoesBack() {
        let dialect = PiRPCDialect()
        let command = "rm -rf build && echo '長い' " + String(repeating: "x", count: 600)
        let asked = dialect.incoming(obj(["type": .string("extension_ui_request"), "id": .string("u1"), "method": .string("confirm"), "title": .string("bash"),
                                         "message": .string(String(decoding: JSONValue.object(["command": .string(command)]).serialized() ?? Data(), as: UTF8.self))]))
        let permission = asked.messages.first
        #expect(permission?["method"]?.string == "session/request_permission" && permission?["id"]?.string == "u1")
        let call = ACPToolCall(permission?["params"]?["toolCall"] ?? .null)
        #expect(call.kind == "execute" && call.command == command)                                    // 切らない：コマンドは、全部を見せる
        let write = dialect.incoming(obj(["type": .string("extension_ui_request"), "id": .string("u2"), "method": .string("confirm"), "title": .string("write"), "message": .string(#"{"path":"/tmp/a.txt","content":"x"}"#)]))
        let editCall = ACPToolCall(write.messages.first?["params"]?["toolCall"] ?? .null)
        #expect(editCall.kind == "edit" && editCall.path == "/tmp/a.txt")
        // 許可・断る・取りやめが、確認の返事になる
        func answer(_ outcome: JSONValue) -> JSONValue? { dialect.outgoing(obj(["jsonrpc": .string("2.0"), "id": .string("u1"), "result": outcome])).lines.first }
        let options = permission?["params"]?["options"]?.array ?? []
        #expect(answer(ACPPermission.outcome(allow: true, options: options))?["confirmed"]?.bool == true)
        #expect(answer(ACPPermission.outcome(allow: false, options: options))?["confirmed"]?.bool == false)
        #expect(answer(ACPPermission.cancelledOutcome)?["cancelled"]?.bool == true)
        // こちらの拡張が使わない種類の質問は、待たせずに、取りやめで返す
        let select = dialect.incoming(obj(["type": .string("extension_ui_request"), "id": .string("u3"), "method": .string("select"), "title": .string("?")]))
        #expect(select.lines.first?["cancelled"]?.bool == true && select.messages.isEmpty)
    }

    @Test func toolsAreMappedToAcpKindsSoThePermissionRulesApply() {
        #expect(["read", "grep", "find", "ls"].allSatisfy { PiRPCDialect.kind(of: $0) == "read" })
        #expect(PiRPCDialect.kind(of: "write") == "edit" && PiRPCDialect.kind(of: "edit") == "edit" && PiRPCDialect.kind(of: "bash") == "execute" && PiRPCDialect.kind(of: "mystery") == "other")
        // 読む道具は、「読む」の段階で、許される。書く・コマンドは、「すべて」でないと、許されない
        let read = ACPToolCall(.object(PiRPCDialect.toolCall(name: "read", input: .object(["path": .string("a.txt")]))))
        let bash = ACPToolCall(.object(PiRPCDialect.toolCall(name: "bash", input: .object(["command": .string("ls")]))))
        #expect(ACPPermission.decide(read, level: .read) == .allow && ACPPermission.decide(bash, level: .read) == .reject)
    }

    @Test func theLaunchArgumentsRemoveTheToolsAtEachLevelAndTheGateExtensionIsOnlyLoadedForAll() throws {
        let profile = try #require(ACPAgentProfile.of(.pi))
        func args(_ level: ChatToolLevel) -> [String] { profile.launch(level: level) }
        #expect(args(.none).contains("--no-tools") && args(.web).contains("--no-tools") && !args(.none).contains("-e"))
        #expect(args(.read).joined(separator: " ").contains("--tools read,grep,find,ls") && !args(.read).contains("-e"))
        #expect(args(.all).contains("-e") && !args(.all).contains("--no-tools"))
        #expect(args(.all).contains("--no-extensions") && args(.all).contains("--no-approve") && args(.all).contains("--mode") && !args(.all).contains("-p"))   // 利用者の拡張・フォルダの設定は、読まない
        #expect(PiGateExtension.source.contains("block: true") && PiGateExtension.source.contains("ctx.ui.confirm"))
    }

    @Test func theGateExtensionFileIsWrittenOnceAndRewrittenWhenItsContentChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vc-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("pi/vc-gate.ts").path
        #expect(PiGateExtension.install(at: path) == path && (try? String(contentsOfFile: path, encoding: .utf8)) == PiGateExtension.source)
        try "古い内容".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(PiGateExtension.install(at: path) == path && (try? String(contentsOfFile: path, encoding: .utf8)) == PiGateExtension.source)   // 古いまま使わない
        #expect(PiGateExtension.install(at: "/dev/null/never/vc-gate.ts") == nil)                                                          // 置けなければ、nil（呼ぶ側は、読むだけに下げる）
    }
}

/// 偽の pi（行ごとの JSON：命令・応答・出来事）。`WRITE` を含む質問は、拡張の `confirm` を出して、答えを待つ。
enum PiFakeAgent {
    static let script = #"""
    import sys, json
    log = open(sys.argv[1], "a")
    def send(o):
        sys.stdout.write(json.dumps(o, ensure_ascii=False) + "\n"); sys.stdout.flush()
    def note(*parts):
        log.write(" ".join(str(p) for p in parts) + "\n"); log.flush()
    def ok(i, command, data=None):
        send({"type": "response", "id": i, "command": command, "success": True, "data": data})
    for line in sys.stdin:
        m = json.loads(line); t = m.get("type"); i = m.get("id")
        note(t, json.dumps({k: v for k, v in m.items() if k not in ("id", "type")}, ensure_ascii=False)[:300])
        if t == "get_state": ok(i, t, {"model": {"provider": "p", "id": "fast"}})
        elif t == "new_session": ok(i, t, {"cancelled": False})
        elif t == "get_available_models": ok(i, t, {"models": [{"provider": "p", "id": "fast", "name": "Fast"}, {"provider": "p", "id": "deep", "name": "Deep"}]})
        elif t == "set_model": ok(i, t, {})
        elif t == "abort": ok(i, t)
        elif t == "prompt":
            ok(i, t, {"disposition": "started"})
            msg = m.get("message", "")
            send({"type": "agent_start"})
            text = "echo:" + msg[-12:]
            if "WRITE" in msg:
                send({"type": "tool_execution_start", "toolCallId": "t1", "toolName": "write", "args": {"path": "b.txt", "content": "hi"}})
                send({"type": "extension_ui_request", "id": "u1", "method": "confirm", "title": "write", "message": json.dumps({"path": "b.txt", "content": "hi"})})
                reply = json.loads(sys.stdin.readline())
                note("ui", json.dumps(reply))
                text = "done" if reply.get("confirmed") else "declined"
                send({"type": "tool_execution_end", "toolCallId": "t1", "toolName": "write", "result": {"content": []}, "isError": not reply.get("confirmed")})
            for part in (text[:2], text[2:]):
                send({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": part}})
            send({"type": "agent_settled", "aborted": False})
    """#
}

@Suite struct PiRPCBackendTests {
    private func backend(tools: ChatToolLevel, model: String? = nil) throws -> (ACPChatBackend, log: String, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vc-pi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("pi.py").path, log = directory.appendingPathComponent("log.txt").path
        try PiFakeAgent.script.write(toFile: script, atomically: true, encoding: .utf8)
        let fallback = ExternalChatBackend(agent: .pi, tools: tools, runner: { _ in AgentRun(exitCode: 0, text: "従来の方式の答え") })
        let backend = ACPChatBackend(agent: .pi, tools: tools, folder: directory, model: model, fallback: fallback, launch: { _, _ in ["python3", script, log] })
        return (backend, log, directory)
    }

    @Test func aQuestionIsAnsweredStreamedAndTheConversationContinuesInTheSameProcess() async throws {
        let (backend, log, directory) = try backend(tools: .read); defer { backend.teardown(); try? FileManager.default.removeItem(at: directory) }
        let chunks = ACPCollected<String>()
        let first = try await backend.respond(instructions: "指示", turns: [], user: "q1", options: ChatCallOptions(onText: { chunks.add($0) }))
        #expect(first == "echo:" + "指示\n\nq1".suffix(12) || first.hasPrefix("echo:"))
        #expect(chunks.all.count == 2 && chunks.all.joined() == first)                      // 少しずつ届いて、つなげると答え
        let turn = ChatTurn(user: "q1", assistant: first)
        let second = try await backend.respond(instructions: "指示", turns: [turn], user: "q2")
        #expect(second == "echo:q2")                                                          // 続きは、いまの発言だけを送る（pi が、会話を覚えている）
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(text.components(separatedBy: "new_session").count == 2)                       // セッションは、1 回だけ
    }

    @Test func aWriteIsConfirmedAndDoesNotRunWhenRefusedAndWhenTheLevelIsReadItIsRefusedWithoutAsking() async throws {
        let (all, _, directory) = try backend(tools: .all); defer { all.teardown(); try? FileManager.default.removeItem(at: directory) }
        let asked = ACPCollected<String>()
        let allowed = try await all.respond(instructions: "", turns: [], user: "WRITE it", options: ChatCallOptions(confirm: { detail in asked.add(detail); return true }))
        #expect(allowed == "done" && asked.all.count == 1 && asked.all[0].contains("b.txt"))
        let refusedBackend = try backend(tools: .all); defer { refusedBackend.0.teardown(); try? FileManager.default.removeItem(at: refusedBackend.directory) }
        let refused = try await refusedBackend.0.respond(instructions: "", turns: [], user: "WRITE it", options: ChatCallOptions(confirm: { _ in false }))
        #expect(refused == "declined")
        // 「読む」の段階では、書き込みは、確認なしで、断る（パネルを、出さない）
        let reader = try backend(tools: .read); defer { reader.0.teardown(); try? FileManager.default.removeItem(at: reader.directory) }
        let asks = ACPCollected<String>()
        let readAnswer = try await reader.0.respond(instructions: "", turns: [], user: "WRITE it", options: ChatCallOptions(confirm: { detail in asks.add(detail); return true }))
        #expect(readAnswer == "declined" && asks.all.isEmpty)
    }

    @Test func theChosenModelIsPassedToPiAsProviderAndId() async throws {
        let (backend, log, directory) = try backend(tools: .read, model: "p/deep"); defer { backend.teardown(); try? FileManager.default.removeItem(at: directory) }
        _ = try await backend.respond(instructions: "", turns: [], user: "hi")
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(text.contains("set_model") && text.contains("\"modelId\": \"deep\"") && text.contains("\"provider\": \"p\""))
    }
}

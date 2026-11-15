import Foundation
import Testing
@testable import VCSkill

/// ACP で話す会話のエージェント：**偽のエージェント**（Python の小さなスクリプト。標準入出力で JSON-RPC を話す）で、セッションの使い回し・会話が替わったときの新しいセッション・許可の確認・使えないときの従来の方式への退避・取りやめ・操作の表示を確かめる。
@Suite(.serialized) struct ACPChatBackendTests {
    private static let script = #"""
    import sys, json
    log = open(sys.argv[1], "a")
    sessions = {}
    def send(o):
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def note(*parts):
        log.write(" ".join(str(p) for p in parts) + "\n"); log.flush()
    for line in sys.stdin:
        m = json.loads(line); method = m.get("method"); mid = m.get("id"); params = m.get("params", {})
        note(method, json.dumps(params, ensure_ascii=False)[:160])
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {}}})
        elif method == "session/new":
            sid = "s%d" % (len(sessions) + 1); sessions[sid] = 0
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid, "models": {"availableModels": [{"modelId": "gemini-4-hydrogen-medium"}]}, "modes": {"availableModes": [{"id": "plan"}, {"id": "default"}]}}})
        elif method in ("session/set_model", "session/set_mode"):
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif method == "session/prompt":
            sid = params["sessionId"]; sessions[sid] += 1
            text = " ".join(b.get("text", "") for b in params["prompt"])
            kinds = [b.get("type") for b in params["prompt"]]
            result = "ok"
            if "TOOL" in text:
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "search", "title": "東京 天気"}}})
            if "WRITE" in text:
                send({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": {"sessionId": sid, "toolCall": {"toolCallId": "t2", "kind": "edit", "title": "File a.txt"}, "options": [{"optionId": "allow", "kind": "allow_once"}, {"optionId": "deny", "kind": "reject_once"}]}})
                reply = json.loads(sys.stdin.readline())
                outcome = reply["result"]["outcome"]
                result = "wrote" if outcome.get("optionId") == "allow" else "denied"
                note("permission", json.dumps(outcome))
            if "SLOW" in text:
                for later in sys.stdin:
                    n = json.loads(later)
                    note(n.get("method"))
                    if n.get("method") == "session/cancel":
                        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "cancelled"}}); break
                continue
            if "EXIT" in text:
                sys.exit(3)
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "%s n=%d len=%d result=%s kinds=%s" % (sid, sessions[sid], len(text), result, ",".join(kinds))}}}})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        elif method == "session/cancel":
            pass
    """#

    private struct Fixture {
        let directory: URL
        let scriptPath: String
        let logPath: String
        var log: String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("vc-acp-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            scriptPath = directory.appendingPathComponent("agent.py").path
            logPath = directory.appendingPathComponent("log.txt").path
            try ACPChatBackendTests.script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        }
        func backend(tools: ChatToolLevel = .read, fallbackText: String = "従来の方式の答え", launches: Counter? = nil, retryAfter: TimeInterval = 600, promptTimeout: TimeInterval = 20) -> ACPChatBackend {
            let script = scriptPath, log = logPath
            let fallback = ExternalChatBackend(agent: .agy, tools: tools, runner: { _ in AgentRun(exitCode: 0, text: fallbackText) })
            return ACPChatBackend(agent: .agy, tools: tools, folder: directory, fallback: fallback,
                                  launch: { _, _ in launches?.increment(); return ["python3", script, log] }, retryAfter: retryAfter, promptTimeout: promptTimeout)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func increment() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }
    private final class Collected<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock(); private var items: [T] = []
        func add(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    @Test func questionsContinueInOneSessionAndOnlyTheFirstCarriesTheHistory() async throws {
        let fx = try Fixture(); let backend = fx.backend(); defer { backend.teardown() }
        let first = try await backend.respond(instructions: "指示", turns: [ChatTurn(user: "前の質問", assistant: "前の答え")], user: "q1")
        #expect(first.contains("s1 n=1") && first.contains("kinds=text"))
        let history = ChatTurn(user: "前の質問", assistant: "前の答え"), turn1 = ChatTurn(user: "q1", assistant: first)
        let second = try await backend.respond(instructions: "指示", turns: [history, turn1], user: "q2")
        #expect(second.contains("s1 n=2"))                       // 同じセッション
        let length = { (text: String) in Int(text.components(separatedBy: "len=")[1].components(separatedBy: " ")[0])! }
        #expect(length(second) == 2 && length(first) > 50)       // 続きは、いまの発言だけ（"q2"）。最初は、指示と過去の往復も入る
        #expect(fx.log.components(separatedBy: "initialize").count == 2)   // 起動は、1 回だけ
    }

    @Test func aChangedConversationStartsANewSessionOnTheSameProcessAndSeedsTheHistory() async throws {
        let fx = try Fixture(); let backend = fx.backend(); defer { backend.teardown() }
        _ = try await backend.respond(instructions: "指示", turns: [], user: "q1")
        // 記録の長さが、続きでなくなった（記録が消えた・古い往復が、要約で落ちた）：新しいセッション。最初に、指示と、残った往復を渡す
        let kept = [ChatTurn(user: "残った質問", assistant: "残った答え"), ChatTurn(user: "もう一つ", assistant: "もう一つの答え")]
        let again = try await backend.respond(instructions: "指示", turns: kept, user: "q2")
        #expect(again.contains("s2 n=1") && again.contains("kinds=text"))
        let reset = try await backend.respond(instructions: "指示", turns: [], user: "q3")
        #expect(reset.contains("s3 n=1"))
        #expect(fx.log.components(separatedBy: "initialize").count == 2)   // プロセスは、使い回す
    }

    @Test func theModelAndTheModeAreSetFromTheLevelAndAvailableList() async throws {
        let fx = try Fixture()
        let readOnly = fx.backend(tools: .read); defer { readOnly.teardown() }
        _ = try await readOnly.respond(instructions: "", turns: [], user: "q")
        #expect(fx.log.contains("session/set_model") && fx.log.contains("gemini-4-hydrogen-medium"))
        #expect(fx.log.contains("\"modeId\": \"plan\"") || fx.log.contains("\"modeId\":\"plan\""))   // 読むだけの段階は、plan
        let all = try Fixture(); let writer = all.backend(tools: .all); defer { writer.teardown() }
        _ = try await writer.respond(instructions: "", turns: [], user: "q")
        #expect(all.log.contains("default"))                                                          // 「すべて」は、確認つきの default
    }

    @Test func permissionRequestsFollowTheLevelAndWritesAreAskedEachTime() async throws {
        let fx = try Fixture(); let writer = fx.backend(tools: .all); defer { writer.teardown() }
        let asked = Collected<String>()
        let yes: ToolConfirm = { detail in asked.add(detail); return true }
        #expect(try await writer.respond(instructions: "", turns: [], user: "WRITE", options: ChatCallOptions(confirm: yes)).contains("result=wrote"))
        #expect(asked.all.count == 1 && asked.all[0].contains("File a.txt"))
        let no: ToolConfirm = { _ in false }
        let turns = [ChatTurn(user: "WRITE", assistant: "x")]
        #expect(try await writer.respond(instructions: "", turns: turns, user: "WRITE", options: ChatCallOptions(confirm: no)).contains("result=denied"))
        let silent = try await writer.respond(instructions: "", turns: turns + [ChatTurn(user: "WRITE", assistant: "y")], user: "WRITE")
        #expect(silent.contains("result=denied"))                  // 確認できない：しない

        let fx2 = try Fixture(); let reader = fx2.backend(tools: .read); defer { reader.teardown() }
        let neverAsked = Collected<String>()
        let spy: ToolConfirm = { detail in neverAsked.add(detail); return true }
        #expect(try await reader.respond(instructions: "", turns: [], user: "WRITE", options: ChatCallOptions(confirm: spy)).contains("result=denied"))
        #expect(neverAsked.all.isEmpty)                            // 読むだけの段階：聞かずに、断る
    }

    @Test func theAgentsToolCallsAreShownAsActivities() async throws {
        let fx = try Fixture(); let backend = fx.backend(tools: .web); defer { backend.teardown() }
        let seen = Collected<ChatActivity>()
        _ = try await backend.respond(instructions: "", turns: [], user: "TOOL", options: ChatCallOptions(onActivity: { seen.add($0) }))
        #expect(seen.all == [ChatActivity.search("東京 天気")])
    }

    @Test func anUnavailableAgentFallsBackToTheOldWayAndIsNotRetriedForAWhile() async throws {
        let launches = Counter()
        let fallback = ExternalChatBackend(agent: .agy, tools: .read, runner: { _ in AgentRun(exitCode: 0, text: "従来の方式の答え") })
        let backend = ACPChatBackend(agent: .agy, tools: .read, fallback: fallback, launch: { _, _ in launches.increment(); return ["vc-no-such-agent-binary-xyz"] })
        defer { backend.teardown() }
        #expect(try await backend.respond(instructions: "", turns: [], user: "q1") == "従来の方式の答え")
        #expect(try await backend.respond(instructions: "", turns: [], user: "q2") == "従来の方式の答え")
        #expect(launches.value == 1)                               // 2 回目は、試さない
    }

    @Test func aBigImageGoesToTheOldWayAndASmallOneIsSentInline() async throws {
        let fx = try Fixture(); let backend = fx.backend(); defer { backend.teardown() }
        let small = fx.directory.appendingPathComponent("small.png"); try Data([0x89, 0x50, 0x4E, 0x47]).write(to: small)
        let inline = try await backend.respond(instructions: "", turns: [], user: "q", options: ChatCallOptions(image: small))
        #expect(inline.contains("kinds=image,text"))
        let big = fx.directory.appendingPathComponent("big.png"); try Data(count: ACPChatBackend.maxImageBytes + 1).write(to: big)
        #expect(try await backend.respond(instructions: "", turns: [], user: "q", options: ChatCallOptions(image: big)) == "従来の方式の答え")
    }

    @Test func cancellingTheTaskSendsSessionCancelAndThrowsCancellation() async throws {
        let fx = try Fixture(); let backend = fx.backend(); defer { backend.teardown() }
        let task = Task { try await backend.respond(instructions: "", turns: [], user: "SLOW") }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fx.log.contains("session/cancel"))
    }

    @Test func aProcessThatDiesMidTurnFailsTheQuestionAndTheNextOneStartsAFreshProcess() async throws {
        let fx = try Fixture(); let launches = Counter(); let backend = fx.backend(launches: launches); defer { backend.teardown() }
        await #expect(throws: ConversationError.self) { _ = try await backend.respond(instructions: "", turns: [], user: "EXIT") }
        let next = try await backend.respond(instructions: "", turns: [], user: "q")
        #expect(next.contains("s1 n=1") && launches.value == 2)    // 新しく起動した
    }
}

/// 許可の確認の答え方（純粋）。
@Suite struct ACPPermissionTests {
    @Test func theLevelDecidesWhichKindsAreAllowedAskedOrRefused() {
        #expect(ACPPermission.decide(kind: "search", level: .none) == .reject && ACPPermission.decide(kind: "search", level: .web) == .allow)
        #expect(ACPPermission.decide(kind: "read", level: .web) == .reject && ACPPermission.decide(kind: "read", level: .read) == .allow)
        for kind in ["edit", "delete", "move", "execute", "other", "switch_mode", "unknown-kind"] {
            #expect(ACPPermission.decide(kind: kind, level: .read) == .reject)
            #expect(ACPPermission.decide(kind: kind, level: .all) == .ask)      // 書き込み・コマンドは、毎回、確認
        }
        #expect(ACPPermission.decide(kind: "think", level: .none) == .allow)
    }

    @Test func theOutcomePicksTheMatchingOptionOrCancels() {
        let options: [JSONValue] = [.object(["optionId": .string("a"), "kind": .string("allow_once")]), .object(["optionId": .string("d"), "kind": .string("reject_once")])]
        #expect(ACPPermission.outcome(allow: true, options: options)["outcome"]?["optionId"]?.string == "a")
        #expect(ACPPermission.outcome(allow: false, options: options)["outcome"]?["optionId"]?.string == "d")
        #expect(ACPPermission.outcome(allow: true, options: [])["outcome"]?["outcome"]?.string == "cancelled")   // 選択肢がない：取りやめ
    }

    @Test func jsonValuesRoundTripAndKeepBooleansDistinctFromNumbers() {
        let value = JSONValue(any: ["a": 1, "b": true, "c": [1.5, "x"], "d": NSNull()] as [String: Any])
        #expect(value["b"]?.bool == true && value["a"]?.int == 1 && value["a"]?.bool == nil)
        #expect(JSONValue.parse(value.serialized()!) == value)
    }
}

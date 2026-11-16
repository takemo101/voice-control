import Foundation
@testable import VCSkill

/// ACP の偽のエージェント（Python の小さなスクリプト。標準入出力で JSON-RPC を話す）と、それを動かす部品。`ACPChatBackendTests` が使う。
enum ACPFakeAgent {
    static let script = #"""
    import sys, json
    log = open(sys.argv[1], "a")
    flavor = sys.argv[2] if len(sys.argv) > 2 else "modes"
    sessions = {}
    def send(o):
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def note(*parts):
        log.write(" ".join(str(p) for p in parts) + "\n"); log.flush()
    for line in sys.stdin:
        m = json.loads(line); method = m.get("method"); mid = m.get("id"); params = m.get("params", {})
        note(method, json.dumps(params, ensure_ascii=False)[:160])
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {"sessionCapabilities": {"close": {}}} if flavor == "config" else {}}})
        elif method == "session/new":
            sid = "s%d" % (len(sessions) + 1); sessions[sid] = 0
            if flavor == "config":
                send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid, "configOptions": [{"id": "mode", "category": "mode", "type": "select", "currentValue": "orchestrator", "options": [{"value": "orchestrator"}, {"value": "build"}, {"value": "plan"}]}]}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid, "models": {"availableModels": [{"modelId": "gemini-4-hydrogen-medium"}]}, "modes": {"availableModes": [{"id": "plan"}, {"id": "default"}]}}})
        elif method in ("session/set_model", "session/set_mode", "session/set_config_option", "session/close"):
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif method == "session/prompt":
            sid = params["sessionId"]; sessions[sid] += 1
            text = " ".join(b.get("text", "") for b in params["prompt"])
            kinds = [b.get("type") for b in params["prompt"]]
            result = "ok"
            if "SHOWRUN" in text:
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "tool_call", "toolCallId": "r1", "kind": "execute", "title": "ls -la"}}})
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "tool_call_update", "toolCallId": "r1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "Created At: 2026\nCommand exited with code 0.\n\nCommand output:\na.txt\r\nb.txt\r\n"}}]}}})
            if "SHOWEDIT" in text:
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "tool_call", "toolCallId": "e1", "kind": "edit", "title": "File a.txt"}}})
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "tool_call_update", "toolCallId": "e1", "status": "completed", "content": [{"type": "diff", "path": "/x/a.txt", "oldText": "one\ntwo\n", "newText": "one\n2\n"}]}}})
            if "TOOL" in text:
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "search", "title": "東京 天気"}}})
            tools = {"WRITE": {"kind": "edit", "title": "File a.txt"},
                     "BASH": {"kind": "execute", "name": "bash", "title": "Run", "rawInput": {"command": "echo hi"}},
                     "RMHOME": {"kind": "execute", "name": "bash", "title": "Run", "rawInput": {"command": "rm -rf ~"}},
                     "LSDIR": {"kind": "execute", "name": "bash", "title": "Run", "rawInput": {"command": "ls -la"}},
                     "GREP": {"kind": "search", "name": "grep", "title": "foo"},
                     "WEBS": {"kind": "other", "name": "websearch", "title": "swift"}}
            for key, tool in tools.items():
                if key not in text: continue
                send({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": {"sessionId": sid, "toolCall": dict(tool, toolCallId="t2"), "options": [{"optionId": "allow", "kind": "allow_once"}, {"optionId": "deny", "kind": "reject_once"}]}})
                reply = None
                while reply is None:   # 取りやめの通知（session/cancel）が、先に来ることがある
                    got = json.loads(sys.stdin.readline())
                    if got.get("id") == 900 and "result" in got: reply = got
                    else: note(got.get("method"))
                outcome = reply["result"]["outcome"]
                result = ("wrote" if key == "WRITE" else key.lower() + "-ok") if outcome.get("optionId") == "allow" else ("cancelled" if outcome.get("outcome") == "cancelled" else "denied")
                note("permission", json.dumps(outcome))
            if result == "cancelled" or (result == "denied" and "REJSTOP" in text):   # 取りやめ・opencode：許可を断ると、その質問を cancelled で終える（答えなし）
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "cancelled"}}); continue
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
}

struct ACPFixture {
    let directory: URL
    let scriptPath: String
    let logPath: String
    var log: String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vc-acp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scriptPath = directory.appendingPathComponent("agent.py").path
        logPath = directory.appendingPathComponent("log.txt").path
        try ACPFakeAgent.script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    }
    func backend(agent: ChatAgent = .agy, tools: ChatToolLevel = .read, fallbackText: String = "従来の方式の答え", launches: ACPCounter? = nil, retryAfter: TimeInterval = 600, promptTimeout: TimeInterval = 20) -> ACPChatBackend {
        let script = scriptPath, log = logPath, flavor = agent == .opencode ? "config" : "modes"
        let fallback = ExternalChatBackend(agent: agent, tools: tools, runner: { _ in AgentRun(exitCode: 0, text: fallbackText) })
        return ACPChatBackend(agent: agent, tools: tools, folder: directory, fallback: fallback,
                              launch: { _, _ in launches?.increment(); return ["python3", script, log, flavor] }, retryAfter: retryAfter, promptTimeout: promptTimeout)
    }
}

final class ACPCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
final class ACPCollected<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

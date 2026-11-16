import Foundation
import Testing
@testable import VCSkill

/// ACP で話す会話のエージェント：**偽のエージェント**（Python の小さなスクリプト。標準入出力で JSON-RPC を話す）で、セッションの使い回し・会話が替わったときの新しいセッション・許可の確認・使えないときの従来の方式への退避・取りやめ・操作の表示を確かめる。
@Suite(.serialized) struct ACPChatBackendTests {
    private static let script = #"""
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
            if "TOOL" in text:
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "search", "title": "東京 天気"}}})
            tools = {"WRITE": {"kind": "edit", "title": "File a.txt"},
                     "BASH": {"kind": "execute", "name": "bash", "title": "Run", "rawInput": {"command": "echo hi"}},
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
        func backend(agent: ChatAgent = .agy, tools: ChatToolLevel = .read, fallbackText: String = "従来の方式の答え", launches: Counter? = nil, retryAfter: TimeInterval = 600, promptTimeout: TimeInterval = 20) -> ACPChatBackend {
            let script = scriptPath, log = logPath, flavor = agent == .opencode ? "config" : "modes"
            let fallback = ExternalChatBackend(agent: agent, tools: tools, runner: { _ in AgentRun(exitCode: 0, text: fallbackText) })
            return ACPChatBackend(agent: agent, tools: tools, folder: directory, fallback: fallback,
                                  launch: { _, _ in launches?.increment(); return ["python3", script, log, flavor] }, retryAfter: retryAfter, promptTimeout: promptTimeout)
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

    @Test func aSilentAgentTimesOutByIdleTimeButASlowHumanConfirmationDoesNot() async throws {
        // 相手が、何も言わない：進みがない時間で、時間切れ（取りやめではなく、失敗）
        let fx = try Fixture(); let silent = fx.backend(promptTimeout: 0.8); defer { silent.teardown() }
        let started = Date()
        await #expect(throws: ConversationError.self) { _ = try await silent.respond(instructions: "", turns: [], user: "SLOW") }
        #expect(Date().timeIntervalSince(started) < 8)
        // 利用者の確認が、時間切れより遅くても、待つ（確認を待つ間は、数えない）
        let fx2 = try Fixture(); let writer = fx2.backend(tools: .all, promptTimeout: 0.6); defer { writer.teardown() }
        let slowYes: ToolConfirm = { _ in try? await Task.sleep(nanoseconds: 1_600_000_000); return true }
        #expect(try await writer.respond(instructions: "", turns: [], user: "WRITE", options: ChatCallOptions(confirm: slowYes)).contains("result=wrote"))
    }

    @Test func cancellingTheQuestionWhileAConfirmationIsPendingCancelsTheConfirmationToo() async throws {
        // 相手からの要求（許可の確認）は、別のタスクで処理される。質問の取りやめ（Esc）が、確認の待ち（パネル）に、届かないと、パネルが、残る（実機の確認で見つけた）
        let fx = try Fixture(); let writer = fx.backend(tools: .all); defer { writer.teardown() }
        let started = Collected<String>(), sawCancellation = Collected<String>()
        let waiting: ToolConfirm = { _ in
            started.add("waiting")
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }   // 利用者が、答えない間
            sawCancellation.add("cancelled")
            return false
        }
        let task = Task { try await writer.respond(instructions: "", turns: [], user: "WRITE", options: ChatCallOptions(confirm: waiting)) }
        while started.all.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        let deadline = Date().addingTimeInterval(3)
        while sawCancellation.all.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(sawCancellation.all == ["cancelled"])
    }

    @Test func anAgentWithConfigOptionsGetsItsModeThroughThemAndAReplacedSessionIsClosed() async throws {
        let fx = try Fixture(); let reader = fx.backend(agent: .opencode, tools: .read); defer { reader.teardown() }
        let first = try await reader.respond(instructions: "", turns: [], user: "q")
        #expect(fx.log.contains("session/set_config_option") && fx.log.contains("\"configId\": \"mode\"") && fx.log.contains("\"value\": \"plan\""))   // 読むだけは、plan
        #expect(!fx.log.contains("session/set_mode") && !fx.log.contains("session/close"))
        // 会話が替わった：新しいセッション。古いのは、閉じる（閉じられると、広告されているとき）
        _ = try await reader.respond(instructions: "", turns: [ChatTurn(user: "別の会話", assistant: "…"), ChatTurn(user: "q", assistant: first)], user: "q2")
        #expect(fx.log.contains("session/close") && fx.log.contains("\"sessionId\": \"s1\""))
        let all = try Fixture(); let writer = all.backend(agent: .opencode, tools: .all); defer { writer.teardown() }
        _ = try await writer.respond(instructions: "", turns: [], user: "q")
        #expect(all.log.contains("\"value\": \"build\""))                                       // 「すべて」は、build
    }

    @Test func toolNamesOpenOnlyReadingAndSearchingAndTheLevelStillDecides() async throws {
        let fx = try Fixture(); let reader = fx.backend(agent: .opencode, tools: .read); defer { reader.teardown() }
        #expect(try await reader.respond(instructions: "", turns: [], user: "GREP").contains("result=grep-ok"))      // 作業フォルダを読む（kind は search だが、Web ではない）
        #expect(try await reader.respond(instructions: "", turns: [ChatTurn(user: "GREP", assistant: "s1 n=1 len=4 result=grep-ok kinds=text")], user: "WEBS").contains("result=webs-ok"))   // 読む段階は、Web も、開く
        let none = try Fixture(); let closed = none.backend(agent: .opencode, tools: .none); defer { closed.teardown() }
        #expect(try await closed.respond(instructions: "", turns: [], user: "GREP").contains("result=denied"))
        let web = try Fixture(); let searcher = web.backend(agent: .opencode, tools: .web); defer { searcher.teardown() }
        #expect(try await searcher.respond(instructions: "", turns: [], user: "WEBS").contains("result=webs-ok"))
        #expect(try await searcher.respond(instructions: "", turns: [ChatTurn(user: "WEBS", assistant: "s1 n=1 len=4 result=webs-ok kinds=text")], user: "GREP").contains("result=denied"))   // Web の段階は、フォルダを読まない
        let bash = try Fixture(); let runner = bash.backend(agent: .opencode, tools: .read); defer { runner.teardown() }
        #expect(try await runner.respond(instructions: "", turns: [], user: "BASH").contains("result=denied"))      // コマンドは、名前が bash でも、読む段階では、断る
    }

    @Test func refusingAConfirmationEndsOpencodesTurnAsCancelledButThatIsAnAnswerNotACancellation() async throws {
        let fx = try Fixture(); let writer = fx.backend(agent: .opencode, tools: .all); defer { writer.teardown() }
        let no: ToolConfirm = { _ in false }
        let answer = try await writer.respond(instructions: "", turns: [], user: "WRITE REJSTOP", options: ChatCallOptions(confirm: no))
        #expect(answer.contains("断った"))   // 利用者の取りやめ（CancellationError）にならない
    }

    @Test func aCancelledQuestionAnswersThePendingPermissionAsCancelled() async throws {
        let fx = try Fixture(); let writer = fx.backend(tools: .all); defer { writer.teardown() }
        let started = Collected<String>()
        let waiting: ToolConfirm = { _ in started.add("waiting"); while !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }; return false }
        let task = Task { try await writer.respond(instructions: "", turns: [], user: "WRITE", options: ChatCallOptions(confirm: waiting)) }
        while started.all.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(fx.log.contains("\"outcome\": \"cancelled\""))   // 仕様：取りやめた質問の許可の要求には、cancelled で答える（断った、ではない）
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
        // 名前：opencode は、grep が search・Web 検索が other。名前で、読む・調べるだけを、開ける
        #expect(ACPPermission.decide(kind: "search", name: "grep", level: .read) == .allow && ACPPermission.decide(kind: "search", name: "grep", level: .web) == .reject)
        #expect(ACPPermission.decide(kind: "other", name: "websearch", level: .web) == .allow && ACPPermission.decide(kind: "other", name: "websearch", level: .none) == .reject)
        #expect(ACPPermission.decide(kind: "other", name: "webfetch", level: .all) == .allow)
        #expect(ACPPermission.decide(kind: "execute", name: "read", level: .read) == .reject)   // 名前を、読む道具に見せかけても、コマンドは、コマンド
        #expect(ACPPermission.decide(kind: "edit", name: "websearch", level: .all) == .ask)
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

    @Test func hiddenAndDirectionChangingCharactersInAConfirmationAreMadeVisible() {
        let folder = URL(fileURLWithPath: "/tmp/vc-acp-folder")
        let run: JSONValue = .object(["rawInput": .object(["command": .string("echo safe\u{202E}evil\u{200B}\nrm -rf x")])])
        let text = ACPPermission.detail(kind: "execute", toolCall: run, folder: folder)
        #expect(text == "コマンドを実行する：echo safe⟨U+202E⟩evil⟨U+200B⟩ rm -rf x")
        let long: JSONValue = .object(["rawInput": .object(["command": .string(String(repeating: "a", count: 700))])])
        #expect(ACPPermission.detail(kind: "execute", toolCall: long, folder: folder).hasSuffix("…（残り 100 文字）"))   // 長いコマンドは、残りの長さを、示す
    }

    @Test func theConfirmationShowsTheRealPathRelativeToTheFolderAndMarksOutsidePaths() {
        let folder = URL(fileURLWithPath: "/tmp/vc-acp-folder")
        func edit(_ path: String) -> JSONValue { .object(["title": .string("File ../../x"), "locations": .array([.object(["path": .string(path)])])]) }
        #expect(ACPPermission.detail(kind: "edit", toolCall: edit("/tmp/vc-acp-folder/notes/a.txt"), folder: folder) == "ファイルを書き込む：notes/a.txt")
        #expect(ACPPermission.detail(kind: "delete", toolCall: edit("/tmp/vc-acp-folder"), folder: folder) == "ファイルを削除する：.")
        let outside = ACPPermission.detail(kind: "edit", toolCall: edit("/etc/hosts"), folder: folder)
        #expect(outside.hasPrefix("ファイルを書き込む：/") && outside.contains("etc/hosts") && outside.hasSuffix("（作業フォルダの外）"))   // 実際の場所（/private/etc/hosts）を、見せる
        #expect(ACPPermission.detail(kind: "edit", toolCall: edit("/tmp/vc-acp-folder/../vc-acp-other/b.txt"), folder: folder).hasSuffix("（作業フォルダの外）"))   // ../ で、外へ出る道は、外
        let run: JSONValue = .object(["title": .string("Run"), "rawInput": .object(["CommandLine": .string("ls -la")])])
        #expect(ACPPermission.detail(kind: "execute", toolCall: run, folder: folder) == "コマンドを実行する：ls -la")
        #expect(ACPPermission.detail(kind: "execute", toolCall: .object(["title": .string("Run something")]), folder: folder) == "コマンドを実行する：Run something")   // 場所・コマンドがなければ、題
    }

    @Test func pathsAreComparedByTheirRealLocationEvenForFilesThatDoNotExistYetAndThroughSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vc-acp-path-\(UUID().uuidString)")   // /var/folders/…（実際は /private/var/…）
        let folder = base.appendingPathComponent("work"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }
        let real = "/private" + folder.path   // エージェントが返す、実際の場所（まだないファイル）
        #expect(ACPPermission.displayPath(real + "/new/a.txt", folder: folder) == "new/a.txt")                 // これから作る・深い場所でも、中
        #expect(ACPPermission.displayPath(folder.appendingPathComponent("b.txt").path, folder: folder) == "b.txt")   // /var の形でも、中
        #expect(ACPPermission.displayPath(folder.path + "/link/c.txt", folder: folder).hasSuffix("（作業フォルダの外）"))   // 中のリンク越しの外は、外
        #expect(ACPPermission.displayPath(outside.appendingPathComponent("d.txt").path, folder: folder).hasSuffix("（作業フォルダの外）"))
    }
}


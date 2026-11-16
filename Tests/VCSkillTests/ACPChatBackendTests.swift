import Foundation
import Testing
@testable import VCSkill

/// ACP で話す会話のエージェント：**偽のエージェント**（Python の小さなスクリプト。標準入出力で JSON-RPC を話す）で、セッションの使い回し・会話が替わったときの新しいセッション・許可の確認・使えないときの従来の方式への退避・取りやめ・操作の表示を確かめる。
@Suite(.serialized) struct ACPChatBackendTests {
    @Test func questionsContinueInOneSessionAndOnlyTheFirstCarriesTheHistory() async throws {
        let fx = try ACPFixture(); let backend = fx.backend(); defer { backend.teardown() }
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
        let fx = try ACPFixture(); let backend = fx.backend(); defer { backend.teardown() }
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
        let fx = try ACPFixture()
        let readOnly = fx.backend(tools: .read); defer { readOnly.teardown() }
        _ = try await readOnly.respond(instructions: "", turns: [], user: "q")
        #expect(fx.log.contains("session/set_model") && fx.log.contains("gemini-4-hydrogen-medium"))
        #expect(fx.log.contains("\"modeId\": \"plan\"") || fx.log.contains("\"modeId\":\"plan\""))   // 読むだけの段階は、plan
        let all = try ACPFixture(); let writer = all.backend(tools: .all); defer { writer.teardown() }
        _ = try await writer.respond(instructions: "", turns: [], user: "q")
        #expect(all.log.contains("default"))                                                          // 「すべて」は、確認つきの default
    }

    @Test func permissionRequestsFollowTheLevelAndWritesAreAskedEachTime() async throws {
        let fx = try ACPFixture(); let writer = fx.backend(tools: .all); defer { writer.teardown() }
        let asked = ACPCollected<String>()
        let yes: ToolConfirm = { detail in asked.add(detail); return true }
        #expect(try await writer.respond(instructions: "", turns: [], user: "WRITE", options: ChatCallOptions(confirm: yes)).contains("result=wrote"))
        #expect(asked.all.count == 1 && asked.all[0].contains("File a.txt"))
        let no: ToolConfirm = { _ in false }
        let turns = [ChatTurn(user: "WRITE", assistant: "x")]
        #expect(try await writer.respond(instructions: "", turns: turns, user: "WRITE", options: ChatCallOptions(confirm: no)).contains("result=denied"))
        let silent = try await writer.respond(instructions: "", turns: turns + [ChatTurn(user: "WRITE", assistant: "y")], user: "WRITE")
        #expect(silent.contains("result=denied"))                  // 確認できない：しない

        let fx2 = try ACPFixture(); let reader = fx2.backend(tools: .read); defer { reader.teardown() }
        let neverAsked = ACPCollected<String>()
        let spy: ToolConfirm = { detail in neverAsked.add(detail); return true }
        #expect(try await reader.respond(instructions: "", turns: [], user: "WRITE", options: ChatCallOptions(confirm: spy)).contains("result=denied"))
        #expect(neverAsked.all.isEmpty)                            // 読むだけの段階：聞かずに、断る
    }

    @Test func theAgentsToolCallsAreShownAsActivities() async throws {
        let fx = try ACPFixture(); let backend = fx.backend(tools: .web); defer { backend.teardown() }
        let seen = ACPCollected<ChatActivity>()
        _ = try await backend.respond(instructions: "", turns: [], user: "TOOL", options: ChatCallOptions(onActivity: { seen.add($0) }))
        #expect(seen.all.map { [$0.kind == .search ? "search" : "?", $0.detail] } == [["search", "東京 天気"]] && seen.all.allSatisfy { $0.id != nil && $0.output == nil })   // 番号つき（結果が来たら、置き換えるため）
    }

    @Test func anUnavailableAgentFallsBackToTheOldWayAndIsNotRetriedForAWhile() async throws {
        let launches = ACPCounter()
        let fallback = ExternalChatBackend(agent: .agy, tools: .read, runner: { _ in AgentRun(exitCode: 0, text: "従来の方式の答え") })
        let backend = ACPChatBackend(agent: .agy, tools: .read, fallback: fallback, launch: { _, _ in launches.increment(); return ["vc-no-such-agent-binary-xyz"] })
        defer { backend.teardown() }
        #expect(try await backend.respond(instructions: "", turns: [], user: "q1") == "従来の方式の答え")
        #expect(try await backend.respond(instructions: "", turns: [], user: "q2") == "従来の方式の答え")
        #expect(launches.value == 1)                               // 2 回目は、試さない
    }

    @Test func aBigImageGoesToTheOldWayAndASmallOneIsSentInline() async throws {
        let fx = try ACPFixture(); let backend = fx.backend(); defer { backend.teardown() }
        let small = fx.directory.appendingPathComponent("small.png"); try Data([0x89, 0x50, 0x4E, 0x47]).write(to: small)
        let inline = try await backend.respond(instructions: "", turns: [], user: "q", options: ChatCallOptions(image: small))
        #expect(inline.contains("kinds=image,text"))
        let big = fx.directory.appendingPathComponent("big.png"); try Data(count: ACPChatBackend.maxImageBytes + 1).write(to: big)
        #expect(try await backend.respond(instructions: "", turns: [], user: "q", options: ChatCallOptions(image: big)) == "従来の方式の答え")
    }

    @Test func cancellingTheTaskSendsSessionCancelAndThrowsCancellation() async throws {
        let fx = try ACPFixture(); let backend = fx.backend(); defer { backend.teardown() }
        let task = Task { try await backend.respond(instructions: "", turns: [], user: "SLOW") }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fx.log.contains("session/cancel"))
    }

    @Test func aSilentAgentTimesOutByIdleTimeButASlowHumanConfirmationDoesNot() async throws {
        // 相手が、何も言わない：進みがない時間で、時間切れ（取りやめではなく、失敗）
        let fx = try ACPFixture(); let silent = fx.backend(promptTimeout: 0.8); defer { silent.teardown() }
        let started = Date()
        await #expect(throws: ConversationError.self) { _ = try await silent.respond(instructions: "", turns: [], user: "SLOW") }
        #expect(Date().timeIntervalSince(started) < 8)
        // 利用者の確認が、時間切れより遅くても、待つ（確認を待つ間は、数えない）
        let fx2 = try ACPFixture(); let writer = fx2.backend(tools: .all, promptTimeout: 0.6); defer { writer.teardown() }
        let slowYes: ToolConfirm = { _ in try? await Task.sleep(nanoseconds: 1_600_000_000); return true }
        #expect(try await writer.respond(instructions: "", turns: [], user: "WRITE", options: ChatCallOptions(confirm: slowYes)).contains("result=wrote"))
    }

    @Test func cancellingTheQuestionWhileAConfirmationIsPendingCancelsTheConfirmationToo() async throws {
        // 相手からの要求（許可の確認）は、別のタスクで処理される。質問の取りやめ（Esc）が、確認の待ち（パネル）に、届かないと、パネルが、残る（実機の確認で見つけた）
        let fx = try ACPFixture(); let writer = fx.backend(tools: .all); defer { writer.teardown() }
        let started = ACPCollected<String>(), sawCancellation = ACPCollected<String>()
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
        let fx = try ACPFixture(); let reader = fx.backend(agent: .opencode, tools: .read); defer { reader.teardown() }
        let first = try await reader.respond(instructions: "", turns: [], user: "q")
        #expect(fx.log.contains("session/set_config_option") && fx.log.contains("\"configId\": \"mode\"") && fx.log.contains("\"value\": \"plan\""))   // 読むだけは、plan
        #expect(!fx.log.contains("session/set_mode") && !fx.log.contains("session/close"))
        // 会話が替わった：新しいセッション。古いのは、閉じる（閉じられると、広告されているとき）
        _ = try await reader.respond(instructions: "", turns: [ChatTurn(user: "別の会話", assistant: "…"), ChatTurn(user: "q", assistant: first)], user: "q2")
        #expect(fx.log.contains("session/close") && fx.log.contains("\"sessionId\": \"s1\""))
        let all = try ACPFixture(); let writer = all.backend(agent: .opencode, tools: .all); defer { writer.teardown() }
        _ = try await writer.respond(instructions: "", turns: [], user: "q")
        #expect(all.log.contains("\"value\": \"build\""))                                       // 「すべて」は、build
    }

    @Test func toolNamesOpenOnlyReadingAndSearchingAndTheLevelStillDecides() async throws {
        let fx = try ACPFixture(); let reader = fx.backend(agent: .opencode, tools: .read); defer { reader.teardown() }
        #expect(try await reader.respond(instructions: "", turns: [], user: "GREP").contains("result=grep-ok"))      // 作業フォルダを読む（kind は search だが、Web ではない）
        #expect(try await reader.respond(instructions: "", turns: [ChatTurn(user: "GREP", assistant: "s1 n=1 len=4 result=grep-ok kinds=text")], user: "WEBS").contains("result=webs-ok"))   // 読む段階は、Web も、開く
        let none = try ACPFixture(); let closed = none.backend(agent: .opencode, tools: .none); defer { closed.teardown() }
        #expect(try await closed.respond(instructions: "", turns: [], user: "GREP").contains("result=denied"))
        let web = try ACPFixture(); let searcher = web.backend(agent: .opencode, tools: .web); defer { searcher.teardown() }
        #expect(try await searcher.respond(instructions: "", turns: [], user: "WEBS").contains("result=webs-ok"))
        #expect(try await searcher.respond(instructions: "", turns: [ChatTurn(user: "WEBS", assistant: "s1 n=1 len=4 result=webs-ok kinds=text")], user: "GREP").contains("result=denied"))   // Web の段階は、フォルダを読まない
        let bash = try ACPFixture(); let runner = bash.backend(agent: .opencode, tools: .read); defer { runner.teardown() }
        #expect(try await runner.respond(instructions: "", turns: [], user: "BASH").contains("result=denied"))      // コマンドは、名前が bash でも、読む段階では、断る
    }

    @Test func refusingAConfirmationEndsOpencodesTurnAsCancelledButThatIsAnAnswerNotACancellation() async throws {
        let fx = try ACPFixture(); let writer = fx.backend(agent: .opencode, tools: .all); defer { writer.teardown() }
        let no: ToolConfirm = { _ in false }
        let answer = try await writer.respond(instructions: "", turns: [], user: "WRITE REJSTOP", options: ChatCallOptions(confirm: no))
        #expect(answer.contains("断った"))   // 利用者の取りやめ（CancellationError）にならない
    }

    @Test func aCancelledQuestionAnswersThePendingPermissionAsCancelled() async throws {
        let fx = try ACPFixture(); let writer = fx.backend(tools: .all); defer { writer.teardown() }
        let started = ACPCollected<String>()
        let waiting: ToolConfirm = { _ in started.add("waiting"); while !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }; return false }
        let task = Task { try await writer.respond(instructions: "", turns: [], user: "WRITE", options: ChatCallOptions(confirm: waiting)) }
        while started.all.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(fx.log.contains("\"outcome\": \"cancelled\""))   // 仕様：取りやめた質問の許可の要求には、cancelled で答える（断った、ではない）
    }

    @Test func catastrophicCommandsAreRefusedWithoutAskingAndHarmlessOnesRunWithoutAsking() async throws {
        let fx = try ACPFixture(); let writer = fx.backend(agent: .opencode, tools: .all); defer { writer.teardown() }
        let asked = ACPCollected<String>()
        let yes: ToolConfirm = { detail in asked.add(detail); return true }
        #expect(try await writer.respond(instructions: "", turns: [], user: "RMHOME", options: ChatCallOptions(confirm: yes)).contains("result=denied"))   // 「はい」と答える用意があっても、断る
        #expect(asked.all.isEmpty)                                                                                                                       // パネルも、出さない
        let ls = try await writer.respond(instructions: "", turns: [ChatTurn(user: "RMHOME", assistant: "s1 n=1 len=6 result=denied kinds=text")], user: "LSDIR", options: ChatCallOptions(confirm: yes))
        #expect(ls.contains("result=lsdir-ok") && asked.all.isEmpty)                                                                                    // 見るだけのコマンドは、確認なしで通る
        let reader = try ACPFixture(); let readOnly = reader.backend(agent: .opencode, tools: .read); defer { readOnly.teardown() }
        #expect(try await readOnly.respond(instructions: "", turns: [], user: "LSDIR").contains("result=lsdir-ok"))                                     // 読む段階でも、作業フォルダの中を見る分は、通る
        let none = try ACPFixture(); let closed = none.backend(agent: .opencode, tools: .web); defer { closed.teardown() }
        #expect(try await closed.respond(instructions: "", turns: [], user: "LSDIR").contains("result=denied"))                                        // フォルダを使わない段階は、断る
    }

    @Test func resultsOfACommandAndAnEditArriveLaterAndReplaceTheSameActivity() async throws {
        let fx = try ACPFixture(); let backend = fx.backend(); defer { backend.teardown() }
        let seen = ACPCollected<ChatActivity>()
        _ = try await backend.respond(instructions: "", turns: [], user: "SHOWRUN SHOWEDIT", options: ChatCallOptions(onActivity: { seen.add($0) }))
        let all = seen.all
        // 同じ番号の操作が、2 回：始まり（結果なし）→ 結果つき
        let run = all.filter { $0.id == "r1" }, edit = all.filter { $0.id == "e1" }
        #expect(run.count == 2 && run[0].output == nil && run[1].output?.text == "Command exited with code 0.\n\nCommand output:\na.txt\nb.txt")
        #expect(edit.count == 2 && edit[1].output?.isDiff == true && edit[1].output?.text == "--- a.txt\n one\n-two\n+2")
        #expect(run[1].kind == .run && run[1].detail == "ls -la" && edit[1].kind == .write)
    }

    @Test func aProcessThatDiesMidTurnFailsTheQuestionAndTheNextOneStartsAFreshProcess() async throws {
        let fx = try ACPFixture(); let launches = ACPCounter(); let backend = fx.backend(launches: launches); defer { backend.teardown() }
        await #expect(throws: ConversationError.self) { _ = try await backend.respond(instructions: "", turns: [], user: "EXIT") }
        let next = try await backend.respond(instructions: "", turns: [], user: "q")
        #expect(next.contains("s1 n=1") && launches.value == 2)    // 新しく起動した
    }
}
import Foundation
import Testing
import VCCore
@testable import VCSkill

/// 会話に使うエージェント（外の CLI）：呼び方（読むだけ・Web なし・履歴なし）・文の組み立て・失敗の区別・取りやめ。CLI は、偽物（実際には、起動しない）。
@Suite struct ChatAgentTests {
    private let dir = URL(fileURLWithPath: "/tmp/work"), out = URL(fileURLWithPath: "/tmp/work/.answer.md")

    @Test func namesAndAliasesResolveAndOnlyApplesStaysInside() {
        #expect(ChatAgent.parse("agy") == .agy && ChatAgent.parse(" Claude ") == .claude && ChatAgent.parse("コーデックス") == .codex && ChatAgent.parse("オープンコード") == .opencode && ChatAgent.parse("fm") == .apple)
        #expect(ChatAgent.parse("gpt") == nil && ChatAgent.parse("") == nil)
        #expect(ChatAgent.allCases.filter { !$0.isExternal } == [.apple])
        #expect(ChatAgent.apple.budget == .standard && ChatAgent.agy.budget.trigger > ChatBudget.standard.trigger)
    }

    @Test func eachToolLevelOpensOnlyWhatItSaysAndTheDefaultIsReadOnly() {
        func args(_ a: ChatAgent, _ level: ChatToolLevel) -> [String] { ExternalChatBackend.arguments(for: a, prompt: "P", directory: dir, answerFile: out, agyModel: "m", tools: level) }
        // claude：道具の一覧と、確認の扱い
        #expect(args(.claude, .none).starts(with: ["-p", "P", "--output-format", "stream-json", "--verbose", "--tools", ""]) && args(.claude, .none).contains("dontAsk"))
        #expect(args(.claude, .web).contains("WebSearch,WebFetch") && !args(.claude, .web).contains { $0.contains("Read") })
        #expect(args(.claude, .read).contains("WebSearch,WebFetch,Read,Glob,Grep") && args(.claude, .read).contains("dontAsk"))
        #expect(!args(.claude, .all).contains("--tools") && args(.claude, .all).contains("bypassPermissions"))   // すべて：道具を絞らず、確認を飛ばす
        // codex：検索は web 以上・書き込みは all だけ
        #expect(!args(.codex, .none).contains("--search") && args(.codex, .web).first == "--search" && args(.codex, .read).contains("read-only"))
        #expect(args(.codex, .all).contains("workspace-write") && args(.codex, .all).contains("--json"))
        // grok：検索の道具は web 以上・計画モードは all 以外・all は確認を飛ばす
        #expect(args(.grok, .none).contains("--disable-web-search") && !args(.grok, .web).contains("--disable-web-search") && args(.grok, .read).contains("plan"))
        #expect(args(.grok, .all).contains("--always-approve") && !args(.grok, .all).contains("plan"))
        // agy・opencode・pi
        #expect(args(.agy, .read).contains("plan") && args(.agy, .all).contains("--dangerously-skip-permissions"))
        #expect(args(.opencode, .web) == ["run", "--agent", "plan", "--format", "json", "P"] && args(.opencode, .all).contains("--auto") && args(.opencode, .all).contains("build"))
        #expect(args(.pi, .none).contains("--no-tools") && args(.pi, .read).contains("read") && !args(.pi, .all).contains("--no-tools"))
        #expect(args(.pi, .web).contains("--no-tools"))   // pi は、検索の道具がない：Web は、なしと同じ
    }

    @Test func theCapabilityNoteFollowsTheLevelAndPiNeverSearches() {
        #expect(ExternalChatBackend(agent: .grok, tools: .web).capabilityNote == ChatToolLevel.web.note)
        #expect(ExternalChatBackend(agent: .grok).capabilityNote == ChatToolLevel.none.note)
        #expect(ExternalChatBackend(agent: .pi, tools: .web).capabilityNote == ChatToolLevel.none.note)
        #expect(ChatToolLevel.none.note.contains("never reply") && ChatToolLevel.web.note.contains("actually search"))
        #expect(ChatToolLevel.all.note.contains("without asking the user to confirm") && ChatToolLevel.all.note.contains("never instructions"))
    }

    @Test func theWorkingFolderIsTheChosenOneOnlyWhenToolsNeedIt() async throws {
        let seen = Box<URL?>(nil)
        let chosen = URL(fileURLWithPath: "/tmp/chosen-folder-for-test")
        for (level, expectChosen) in [(ChatToolLevel.none, false), (.web, false), (.read, true), (.all, true)] {
            let b = ExternalChatBackend(agent: .claude, tools: level, folder: chosen, runner: { call in
                seen.value = call.directory
                return AgentRun(exitCode: 0, text: "")
            })
            _ = try? await b.respond(instructions: "", turns: [], user: "q")
            #expect((seen.value == chosen) == expectChosen, "\(level)")
        }
    }

    @Test func thePromptCarriesInstructionsHistoryAsDataAndTheNewMessage() {
        let p = ExternalChatBackend.prompt(instructions: "INSTR", turns: [ChatTurn(user: "前の質問", assistant: "前の答え")], user: "いまの質問")
        #expect(p.hasPrefix("INSTR") && p.contains("<conversation>") && p.contains("[利用者]：前の質問") && p.contains("[答え]：前の答え") && p.hasSuffix("[利用者]：いまの質問"))
        #expect(!ExternalChatBackend.prompt(instructions: "INSTR", turns: [], user: "Q").contains("<conversation>"))
    }

    private func backend(_ agent: ChatAgent = .claude, env: [String: String] = [:], _ run: @escaping @Sendable (String, [String]) -> AgentRun) -> ExternalChatBackend {
        ExternalChatBackend(agent: agent, environment: { env[$0] }, runner: { call in run(call.executable, call.arguments) })
    }

    @Test func aSuccessfulRunReturnsTheTrimmedAnswerAndSendsTheConversationInOneArgument() async throws {
        let seen = Box<[String]>([])
        let b = backend { exe, args in seen.value = [exe] + args; return AgentRun(exitCode: 0, text: "  こんにちは  \n") }
        let answer = try await b.respond(instructions: "I", turns: [ChatTurn(user: "a", assistant: "b")], user: "c")
        #expect(answer == "こんにちは")
        #expect(seen.value.first == "claude" && seen.value.contains { $0.contains("[利用者]：a") && $0.contains("[利用者]：c") })
    }

    @Test func failuresAreToldApartAndNeverFallBackSilently() async {
        await #expect(throws: ConversationError.self) { try await backend { _, _ in AgentRun(exitCode: 127, text: "") }.respond(instructions: "", turns: [], user: "q") }
        do { _ = try await backend { _, _ in AgentRun(exitCode: 127, text: "") }.respond(instructions: "", turns: [], user: "q"); Issue.record("失敗するはず") }
        catch let e as ConversationError { if case .unavailable = e {} else { Issue.record("入っていない → unavailable：\(e)") } } catch { Issue.record("\(error)") }
        do { _ = try await backend { _, _ in AgentRun(exitCode: 1, text: "x") }.respond(instructions: "", turns: [], user: "q"); Issue.record("失敗するはず") }
        catch let e as ConversationError { #expect(e.description.contains("ログイン")) } catch { Issue.record("\(error)") }
        do { _ = try await backend { _, _ in AgentRun(exitCode: 0, text: "  \n") }.respond(instructions: "", turns: [], user: "q"); Issue.record("失敗するはず") }
        catch let e as ConversationError { #expect(e.description.contains("空")) } catch { Issue.record("\(error)") }
        do { _ = try await backend { _, _ in AgentRun(exitCode: 15, text: "", timedOut: true) }.respond(instructions: "", turns: [], user: "q"); Issue.record("失敗するはず") }
        catch let e as ConversationError { #expect(e.description.contains("時間内")) } catch { Issue.record("\(error)") }
    }

    @Test func cancellationIsReportedAsCancellation() async {
        let b = backend { _, _ in AgentRun(exitCode: 130, text: "", cancelled: true) }
        await #expect(throws: CancellationError.self) { try await b.respond(instructions: "", turns: [], user: "q") }
    }

    @Test func theAgyModelComesFromTheEnvironmentButOnlyInASafeShape() async throws {
        let seen = Box<[String]>([])
        let ok = backend(.agy, env: ["ASK_AGENT_AGY_MODEL": "gemini-3.8-flash-high"]) { _, args in seen.value = args; return AgentRun(exitCode: 0, text: "ok") }
        _ = try await ok.respond(instructions: "", turns: [], user: "q")
        #expect(seen.value.contains("gemini-3.8-flash-high"))
        let bad = backend(.agy, env: ["ASK_AGENT_AGY_MODEL": "x --dangerously-skip-permissions"]) { _, _ in AgentRun(exitCode: 0, text: "ok") }
        await #expect(throws: ConversationError.self) { try await bad.respond(instructions: "", turns: [], user: "q") }
        let none = backend(.agy) { _, args in seen.value = args; return AgentRun(exitCode: 0, text: "ok") }
        _ = try await none.respond(instructions: "", turns: [], user: "q")
        #expect(seen.value.contains(ExternalChatBackend.agyDefaultModel))
    }

    /// 偽の実行が、呼び出しの引数を書き残すための箱。
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock(); private var stored: T
        init(_ value: T) { stored = value }
        var value: T { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
    }
}

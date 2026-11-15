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

    @Test func everyAgentIsRunReadOnlyWithoutWebAndKeepsNoHistoryWhereThereIsAnOption() {
        func args(_ a: ChatAgent) -> [String] { ExternalChatBackend.arguments(for: a, prompt: "P", directory: dir, answerFile: out, agyModel: "m") }
        #expect(args(.agy).contains("plan") && args(.agy).contains("--sandbox") && args(.agy).starts(with: ["-p", "P"]))
        #expect(args(.claude).contains("--no-session-persistence") && args(.claude).starts(with: ["-p", "P", "--tools", ""]))   // 道具は、空（Web も、ファイルも、端末も、ない）
        #expect(args(.codex).contains("read-only") && args(.codex).contains("--ephemeral") && !args(.codex).contains("--search") && args(.codex).last == "P")
        #expect(args(.grok).contains("--disable-web-search") && args(.grok).contains("plan"))
        #expect(args(.opencode) == ["run", "--agent", "plan", "P"])
        #expect(args(.pi).contains("--no-tools") && args(.pi).contains("--no-session"))
        #expect(args(.apple).isEmpty)
    }

    @Test func webSearchOpensOnlyTheSearchToolsAndOnlyWhenAsked() {
        func args(_ a: ChatAgent, web: Bool) -> [String] { ExternalChatBackend.arguments(for: a, prompt: "P", directory: dir, answerFile: out, agyModel: "m", web: web) }
        #expect(args(.claude, web: false).starts(with: ["-p", "P", "--tools", ""]) && !args(.claude, web: false).contains("--allowedTools"))
        #expect(args(.claude, web: true).starts(with: ["-p", "P", "--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch"]))   // ファイル・端末の道具は、開けない
        #expect(!args(.codex, web: false).contains("--search") && args(.codex, web: true).first == "--search" && args(.codex, web: true).contains("read-only"))
        #expect(args(.grok, web: false).contains("--disable-web-search") && !args(.grok, web: true).contains("--disable-web-search") && args(.grok, web: true).contains("plan"))
    }

    @Test func theCapabilityNoteTellsTheAgentWhetherItCanSearchAndPiNeverCan() {
        #expect(ExternalChatBackend(agent: .grok, web: true).capabilityNote == ChatCapability.web)
        #expect(ExternalChatBackend(agent: .grok).capabilityNote == ChatCapability.noWeb)
        #expect(ExternalChatBackend(agent: .pi, web: true).capabilityNote == ChatCapability.noWeb)   // pi は、検索の道具がない
        #expect(ChatCapability.noWeb.contains("never reply") && ChatCapability.web.contains("actually search"))
    }

    @Test func thePromptCarriesInstructionsHistoryAsDataAndTheNewMessage() {
        let p = ExternalChatBackend.prompt(instructions: "INSTR", turns: [ChatTurn(user: "前の質問", assistant: "前の答え")], user: "いまの質問")
        #expect(p.hasPrefix("INSTR") && p.contains("<conversation>") && p.contains("[利用者]：前の質問") && p.contains("[答え]：前の答え") && p.hasSuffix("[利用者]：いまの質問"))
        #expect(!ExternalChatBackend.prompt(instructions: "INSTR", turns: [], user: "Q").contains("<conversation>"))
    }

    private func backend(_ agent: ChatAgent = .claude, env: [String: String] = [:], _ run: @escaping @Sendable (String, [String]) -> AgentRun) -> ExternalChatBackend {
        ExternalChatBackend(agent: agent, environment: { env[$0] }, runner: { exe, args, _, _, _ in run(exe, args) })
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

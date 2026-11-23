import Foundation
import Testing
@testable import VCSkill

/// 会話の答える側が「ローカルのサーバー」のとき：送る並び・失敗の区別・選べる条件（偽のサーバー）。
@Suite struct ModelServerChatBackendTests {
    private final class Fake: ChatModel, @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<String, ChatError>
        private(set) var sent: [(messages: [ChatMessage], tools: Bool)] = []
        init(_ outcome: Result<String, ChatError>) { self.outcome = outcome }
        func chat(_ messages: [ChatMessage], tools: Bool) async throws -> ChatMessage {
            lock.lock(); defer { lock.unlock() }
            sent.append((messages, tools))
            return ChatMessage(role: .assistant, content: try outcome.get())
        }
    }

    @Test func theRequestCarriesInstructionsThenEachPastTurnThenTheNewMessageWithoutTools() async throws {
        let fake = Fake(.success("  はい、青です。\n"))
        let backend = ModelServerChatBackend(chat: fake)
        let answer = try await backend.respond(instructions: "SYS", turns: [ChatTurn(user: "好きな色は青", assistant: "覚えました"), ChatTurn(user: "ありがとう", assistant: "どういたしまして")], user: "私の好きな色は？")
        #expect(answer == "はい、青です。")   // 前後の空白は、落とす
        let sent = try #require(fake.sent.first)
        #expect(sent.tools == false)   // 会話は、道具なし（`run_command` を、渡さない）
        #expect(sent.messages.map(\.role) == [.system, .user, .assistant, .user, .assistant, .user])
        #expect(sent.messages.first?.content == "SYS" && sent.messages.last?.content == "私の好きな色は？")
    }

    @Test func serverFailuresAndEmptyAnswersSurfaceAsAConversationFailureWithTheServersReason() async {
        for (outcome, expected) in [(Result<String, ChatError>.failure(.timedOut(server: "S", endpoint: "127.0.0.1:1")), "127.0.0.1:1"), (.failure(.http(500, "boom")), "500"), (.success(" \n"), "空")] {
            do { _ = try await ModelServerChatBackend(chat: Fake(outcome)).respond(instructions: "", turns: [], user: "q"); Issue.record("失敗するはず") }
            catch let ConversationError.failed(message) { #expect(message.contains(expected)) }
            catch { Issue.record("別の失敗: \(error)") }
        }
    }

    @Test func theServerAgentStaysInsideTheUsersChoiceAndOnlyAnswersWhenAServerEngineIsChosen() throws {
        #expect(!ChatAgent.server.isExternal && ChatAgent.parse("Ollama") == .server && ChatAgent.parse("サーバー") == .server)
        #expect(ChatAgent.server.effective(.all) == .none && ChatAgent.server.effective(.web) == .none)   // 道具は、開けない
        let engine = try Engine.parse("ollama:qwen3")
        #expect(ChatAgent.server.canAnswer(with: engine) && !ChatAgent.server.canAnswer(with: .apple))
        #expect(ChatAgent.apple.canAnswer(with: .apple) && ChatAgent.claude.canAnswer(with: .apple))
        #expect(ChatAgent.server.makeBackend(engine: engine) is ModelServerChatBackend)
        #expect(!(ChatAgent.server.makeBackend(engine: .apple) is ModelServerChatBackend))   // 行き先がないとき、サーバーのふりをしない（呼ぶ側が、先に断る）
    }
}

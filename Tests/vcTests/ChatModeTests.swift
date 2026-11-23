import Testing
@testable import vc
import VCSkill
import VCSpeech

enum HotKeySpecTestHelper {
    static func parse(_ text: String) throws -> HotKeySpec { try HotKeySpec.parse(text).get() }
}

/// 会話のモード：キーの重なりの確認。
@MainActor @Suite struct ChatModeTests {
    @Test func aChatKeyThatOverlapsAnotherIsRefused() throws {
        let listen = try HotKeySpecTestHelper.parse("rshift"), dictate = try HotKeySpecTestHelper.parse("rcmd")
        #expect(KeyConflicts.message(listen: listen, dictate: dictate, shot: nil, chat: try HotKeySpecTestHelper.parse("ropt")) == nil)
        #expect(KeyConflicts.message(listen: listen, dictate: dictate, shot: nil, chat: try HotKeySpecTestHelper.parse("rcmd"))?.contains("会話") == true)
        #expect(KeyConflicts.message(listen: listen, dictate: dictate, shot: nil, chat: try HotKeySpecTestHelper.parse("shift"))?.contains("声で頼む") == true)
    }

    @Test func onlyAServerAnswerOnANonLoopbackHostCountsAsSendingOverTheLAN() throws {
        func lan(_ agent: ChatAgent, _ engine: String) throws -> Bool { ChatSetup(agent: agent, engine: try Engine.parse(engine)).sendsOverLAN }
        #expect(try lan(.server, "openai:m@192.168.0.5:8080"))
        #expect(try !lan(.server, "ollama:m"))   // この Mac の 127.0.0.1
        #expect(try !lan(.apple, "openai:m@192.168.0.5:8080"))   // 会話の相手が Apple なら、サーバーへは、送らない
        #expect(!ChatSetup(agent: .server).sendsOverLAN)   // エンジンが Apple（行き先なし）
    }

    @Test func anImageReadByAServerOnTheLANIsNotLabelledAsProcessedOnThisMac() throws {
        #expect(ChatMode.ImageRoute.digested(by: .apple) == .local)
        #expect(try ChatMode.ImageRoute.digested(by: Engine.parse("ollama:m")) == .local)   // この Mac の 127.0.0.1
        #expect(try ChatMode.ImageRoute.digested(by: Engine.parse("ollama:m@192.168.0.5:11434")) == .lan)
    }
}

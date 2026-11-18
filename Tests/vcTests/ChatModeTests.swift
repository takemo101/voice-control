import Testing
@testable import vc
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
}

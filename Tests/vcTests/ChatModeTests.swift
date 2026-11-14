import Testing
@testable import vc
import VCSpeech

enum HotKeySpecTestHelper {
    static func parse(_ text: String) throws -> HotKeySpec { try HotKeySpec.parse(text).get() }
}

/// 会話のモード：「会話を終わる」の見分け・答えの見せ方・読み上げる文。
@MainActor @Suite struct ChatModeTests {
    @Test func endCommandsAreRecognizedByWordsNotByTheModel() {
        for text in ["会話を終わって", "会話を終了して", "新しい会話", "新しい会話にして", "会話をリセット", "会話を、終わって。", "もう会話をやめて", "忘れて", "全部忘れて", "会話終了"] {
            #expect(ChatMode.isEndCommand(text), "\(text)")
        }
        for text in ["会話の続きだけど", "東京の人口は？", "忘れ物をしないコツは？", "終わりの挨拶を考えて", "忘れていた予定を整理して", ""] {
            #expect(!ChatMode.isEndCommand(text), "\(text)")
        }
    }

    @Test func shortSingleLineAnswersGoToThePanelAndLongOnesToTheWindow() {
        #expect(ChatMode.isShort("青です。"))
        #expect(!ChatMode.isShort(String(repeating: "あ", count: 111)))
        #expect(!ChatMode.isShort("一行目\n二行目"))
    }

    @Test func spokenAnswersAreCutAtASentenceBoundary() {
        #expect(ChatVoice.spoken("青です。") == "青です。")
        let long = (1...30).map { "これは、ながい、ぶんしょうの、\($0) ばんめの文です" }.joined(separator: "。")
        let spoken = ChatVoice.spoken(long)
        #expect(spoken.count <= 170 && spoken.hasSuffix("。") && spoken.contains("1 ばんめ") && !spoken.contains("30 ばんめ"))
    }

    @Test func aChatKeyThatOverlapsAnotherIsRefused() throws {
        let listen = try HotKeySpecTestHelper.parse("rshift"), dictate = try HotKeySpecTestHelper.parse("rcmd")
        #expect(KeyConflicts.message(listen: listen, dictate: dictate, shot: nil, chat: try HotKeySpecTestHelper.parse("ropt")) == nil)
        #expect(KeyConflicts.message(listen: listen, dictate: dictate, shot: nil, chat: try HotKeySpecTestHelper.parse("rcmd"))?.contains("会話") == true)
        #expect(KeyConflicts.message(listen: listen, dictate: dictate, shot: nil, chat: try HotKeySpecTestHelper.parse("shift"))?.contains("声で頼む") == true)
    }
}

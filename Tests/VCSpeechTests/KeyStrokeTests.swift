import Testing
@testable import VCCore
@testable import VCSpeech

/// 入力のあとに送るキー：書き方（設定ファイル・設定画面の記録）と、既定。
@Suite struct KeyStrokeTests {
    @Test func plainKeysAndModifiedKeysParseAndRoundTripToTheirNormalForm() throws {
        #expect(try KeyStroke.parse("return").get() == .enter)
        #expect(try KeyStroke.parse("Enter").get() == .enter)                                     // 別名・大文字
        let command = try KeyStroke.parse("cmd+return").get()
        #expect(command.modifiers == [.command] && command.key == "return" && command.description == "cmd+return")
        #expect(try KeyStroke.parse("return+shift+ctrl").get().description == "ctrl+shift+return")   // 順序は、正規化する
        #expect(try KeyStroke.parse("tab").get().displayName == "Tab")                           // 単独のキーも、よい（トリガーとの違い）
        #expect(try KeyStroke.parse("alt-return").get().displayName == "⌥Enter")
        #expect(KeyStroke.enter.displayName == "Enter")
    }

    @Test func nothingToPressOrUnknownKeysAreRejectedWithAReason() {
        for bad in ["", "  ", "cmd", "shift+ctrl", "cmd+", "+return", "a+b", "cmd+コ", "return+tab"] {
            if case .success(let stroke) = KeyStroke.parse(bad) { Issue.record("読めてしまった：\(bad) → \(stroke)") }
        }
    }

    @Test func anUnsetOrBrokenSettingFallsBackToEnterOnlyWhenUnset() {
        var settings = Settings()
        #expect((try? settings.dictateKeyStroke.get()) == .enter)                                // なければ、Enter
        settings.dictateKey = "cmd+return"
        #expect((try? settings.dictateKeyStroke.get())?.description == "cmd+return")
        settings.dictateKey = "nonsense"
        if case .success = settings.dictateKeyStroke { Issue.record("壊れた設定が、黙って、Enter になった") }   // 成功に見える代用品にしない
    }
}

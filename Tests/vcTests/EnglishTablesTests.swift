import Testing
@testable import vc

/// 英語の表：実行時に読み込める（Swift の辞書の文字は、鍵が重なると、起動で落ちる）・どの鍵も、空でない英語を持ち、置き換えの数が、日本語の鍵と同じ。
@Suite struct EnglishTablesTests {
    @Test func everyEntryHasANonEmptyEnglishValueWithTheSamePlaceholders() {
        #expect(EnglishTables.all.count > 100)
        for (key, value) in EnglishTables.all {
            #expect(!value.isEmpty, "空：\(key)")
            let slots = key.components(separatedBy: "%@").count - 1
            let plain = value.components(separatedBy: "%@").count - 1
            let numbered = Set((value.range(of: #"%\d+\$@"#, options: .regularExpression) == nil ? [] : (1...max(slots, 1)).filter { value.contains("%\($0)$@") }))
            let ok = (plain == slots && numbered.isEmpty) || (plain == 0 && numbered == Set(1...max(slots, 1)).filter { $0 <= slots })
            #expect(ok, "置き換えの数が違う：\(key) → \(value)")
        }
    }
}

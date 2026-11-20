import Testing
import VCCore
@testable import vc

/// 翻訳の表：どの言語の表も、読み込める（Swift の辞書の文字は、鍵が重なると、起動で落ちる）・訳のある項目は、置き換えの数が鍵と合う。**英語は、空の値を持たない**（すべての言語の引き先）。
@Suite struct LanguageTablesTests {
    private func placeholdersMatch(_ key: String, _ value: String) -> Bool {
        let slots = key.components(separatedBy: "%@").count - 1
        let plain = value.components(separatedBy: "%@").count - 1
        let numbered = Set((1...max(slots, 1)).filter { value.contains("%\($0)$@") })
        return (plain == slots && numbered.isEmpty) || (plain == 0 && numbered == Set((1...max(slots, 1)).filter { $0 <= slots }))
    }

    @Test func everyRegisteredLanguageHasATableWithMatchingPlaceholders() {
        for language in AppLanguage.allCases where language != .ja {
            let table = L10nTables.table(for: language)
            #expect(!table.isEmpty, "\(language)：表が、登録されていない")
            for (key, value) in table where !value.isEmpty {
                #expect(placeholdersMatch(key, value), "置き換えの数が違う（\(language)）：\(key) → \(value)")
            }
        }
    }

    @Test func theEnglishTableHasNoUntranslatedEntries() {
        let english = L10nTables.table(for: .en)
        #expect(english.count > 100 && english == EnglishTables.all)
        #expect(english.filter { $0.value.isEmpty }.isEmpty)   // 空の値（未訳）は、英語に、置かない：ほかの言語の引き先
    }

    @Test func japaneseNeedsNoTableBecauseTheKeyIsTheText() {
        #expect(L10nTables.table(for: .ja).isEmpty)
    }
}

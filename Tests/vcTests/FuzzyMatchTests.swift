import Testing
@testable import vc

/// あいまい検索：順に含まれる・語はすべて含む・よく合う順。
@Suite struct FuzzyMatchTests {
    private let models = ["default Default (recommended)", "opus Opus 5.5", "sonnet Sonnet 5.5", "haiku Haiku 5.5", "claude-sonnet-4-6 Sonnet 4.6", "claude-haiku-4-5-20251001 Haiku 4.5",
                          "gpt-6.2-sol[high] 6.2 Sol (high)", "gpt-6.2-sol[low] 6.2 Sol (low)", "gpt-6.2-astra[high] 6.2 Astra (high)"]

    private func find(_ query: String) -> [String] { FuzzyMatch.filter(models, query: query) { $0 }.map { String($0.split(separator: " ").first ?? "") } }

    @Test func charactersMatchInOrderEvenWithGapsAndCaseAndWidthAreIgnored() {
        #expect(find("snt").first == "sonnet")                       // s…n…n…t：間が空いてもよい
        #expect(find("SON").contains("sonnet"))                      // 大文字・小文字は、区別しない
        #expect(find("ｓｏｎ").contains("sonnet"))                    // 全角も
        #expect(find("tnos").isEmpty)                                // 順が違えば、合わない
        #expect(find("zzz").isEmpty)
    }

    @Test func everyWordMustMatchAndTheFirstExactSubstringsComeFirst() {
        #expect(find("son 5") == ["sonnet"])                          // 「5」を含むものだけ（Sonnet 4.6 は、合わない）
        #expect(find("high gpt").allSatisfy { $0.hasPrefix("gpt") } && Set(find("high gpt")) == ["gpt-6.2-sol[high]", "gpt-6.2-astra[high]"])
        #expect(find("haiku 4").first == "claude-haiku-4-5-20251001")
        #expect(find("sol low") == ["gpt-6.2-sol[low]"])
    }

    @Test func aWholeWordBeatsAScatteredMatchAndAStartOfWordBeatsTheMiddle() {
        let items = ["xsxoxn", "sonnet", "reason"]
        #expect(FuzzyMatch.filter(items, query: "son") { $0 } == ["sonnet", "reason", "xsxoxn"])   // 連続（語頭）＞連続（途中）＞ばらばら
    }

    @Test func anEmptyQueryKeepsEverythingInTheOriginalOrderAndTiesKeepTheirOrder() {
        #expect(FuzzyMatch.filter(models, query: "") { $0 } == models)
        #expect(FuzzyMatch.filter(models, query: "   ") { $0 } == models)
        #expect(FuzzyMatch.filter(["ab1", "ab2", "ab3"], query: "ab") { $0 } == ["ab1", "ab2", "ab3"])   // 同点は、元の順
        #expect(FuzzyMatch.score("", in: "anything") == 0 && FuzzyMatch.score("x", in: "abc") == nil)
    }

    @Test func japaneseNamesAreMatchedToo() {
        let names = ["claude-opus 作業用", "gemini 会話用", "codex 検索"]
        #expect(FuzzyMatch.filter(names, query: "会話") { $0 } == ["gemini 会話用"])
    }
}

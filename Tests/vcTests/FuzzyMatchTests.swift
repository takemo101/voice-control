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

    // MARK: 強調する位置

    @Test func matchedPositionsPointAtTheOriginalCharactersEvenForCaseWidthAndJapanese() {
        #expect(FuzzyMatch.match("son", in: "Sonnet 5.5")?.positions == [0, 1, 2])
        #expect(FuzzyMatch.match("snt", in: "sonnet")?.positions == [0, 2, 5])                       // 間が空いた文字だけ
        #expect(FuzzyMatch.match("ｓｏｎ", in: "Sonnet")?.positions == [0, 1, 2])                      // 全角の入力でも、元の位置
        #expect(FuzzyMatch.match("son 5", in: "Sonnet 5.5")?.positions == [0, 1, 2, 7])               // 語ごとの合った所を、まとめる
        #expect(FuzzyMatch.match("会話", in: "gemini 会話用")?.positions == [7, 8])
        #expect(FuzzyMatch.match("", in: "x") == FuzzyMatch.Match(score: 0, positions: []))
        #expect(FuzzyMatch.match("x", in: "abc") == nil)
    }

    @Test func highlightingUsesOnlyTheWordsThatMatchThatFieldAndPrefersTheBestOccurrence() {
        #expect(FuzzyMatch.highlight("son 5", in: "claude-sonnet-5") == [7, 8, 9, 14])               // 名前と値を、別々に強調する：合う語だけ
        #expect(FuzzyMatch.highlight("son 5", in: "Opus 5.5") == [5])                                 // 「son」は、ここには合わない：「5」だけ
        // 同じ語が、2 か所にあれば、語頭の所を選ぶ（途中の所でなく）
        #expect(FuzzyMatch.match("opus", in: "xopus opus")?.positions == [6, 7, 8, 9])
    }

    // MARK: 一覧の見せ方

    private func item(_ id: String, _ name: String? = nil) -> ModelListLogic.Item { .init(id: id, name: name ?? id, detail: nil) }

    @Test func aLongListWithoutAQueryIsSplitByProviderOrModelAndASearchIsNeverSplit() {
        let opencode = [item("openai/gpt-6.2"), item("google/gemini-4"), item("openai/gpt-6.2-mini"), item("loose")]
        let sections = ModelListLogic.sections(opencode, query: "")
        #expect(sections.map(\.title) == ["openai", "google", "そのほか"])                              // 現れた順・鍵のないものは、最後
        #expect(sections[0].items.map(\.id) == ["openai/gpt-6.2", "openai/gpt-6.2-mini"])
        let codex = [item("gpt-6.2-sol[low]"), item("gpt-6.2-sol[high]"), item("gpt-6.2-astra[low]")]
        #expect(ModelListLogic.sections(codex, query: "").map(\.title) == ["gpt-6.2-sol", "gpt-6.2-astra"])
        #expect(ModelListLogic.sections(opencode, query: "gpt").count == 1 && ModelListLogic.sections(opencode, query: "gpt")[0].title == nil)   // 検索中は、1 つの並び
        #expect(ModelListLogic.sections([item("haiku"), item("sonnet"), item("opus")], query: "").count == 1)                            // 鍵がなければ、分けない
        #expect(ModelListLogic.sections([item("a/x"), item("a/y"), item("b"), item("c"), item("d")], query: "").count == 1)             // 鍵を持つものが、半分以下なら、分けない
        #expect(ModelListLogic.sections([item("a/x"), item("a/y")], query: "").count == 1)                                                // 鍵が 1 種類だけなら、分けない
    }

    @Test func arrowKeysMoveTheHighlightAndStopAtTheEnds() {
        let ids = ["", "a", "b", "c"]
        #expect(ModelListLogic.moved(from: nil, by: 1, in: ids) == "" && ModelListLogic.moved(from: nil, by: -1, in: ids) == "c")
        #expect(ModelListLogic.moved(from: "a", by: 1, in: ids) == "b" && ModelListLogic.moved(from: "a", by: -1, in: ids) == "")
        #expect(ModelListLogic.moved(from: "c", by: 1, in: ids) == "c" && ModelListLogic.moved(from: "", by: -1, in: ids) == "")   // 端で、止まる
        #expect(ModelListLogic.moved(from: "gone", by: 1, in: ids) == "")                                                          // 一覧にない行からは、先頭へ
        #expect(ModelListLogic.moved(from: "a", by: 1, in: []) == nil)
    }
}


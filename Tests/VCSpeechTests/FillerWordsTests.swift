import Testing
@testable import VCSpeech

/// つなぎ言葉の除去：消すもの・消さないもの（意味のある語を、巻き込まない）・前後の整形・辞書の検査。
@Suite struct FillerWordsTests {
    private func clean(_ text: String, _ fillers: [String] = FillerWords.defaults) -> String { FillerWords.remove(from: text, fillers: fillers) }

    // MARK: 日本語

    @Test func aFillerAtTheStartGoesWithItsComma() {
        #expect(clean("えーと、今日は晴れです") == "今日は晴れです")
        #expect(clean("ええと今日は晴れです") == "今日は晴れです")
    }

    @Test func aFillerBetweenPhrasesKeepsOneSeparator() {
        #expect(clean("今日は、えーと、明日行きます") == "今日は、明日行きます")
        // 直前が文字で、読点が付いている：区切りを、1 つ残す
        #expect(clean("今日はえーと、明日行きます") == "今日は、明日行きます")
    }

    @Test func consecutiveFillersAreAllRemoved() {
        #expect(clean("えーと、えーっと、あのー、今日は") == "今日は")
        #expect(clean("うーん、えー、そうですね") == "そうですね")
    }

    /// ふつうの語・ほかの語の一部は、消さない（既定の辞書に「あの」「その」「まあ」は、入っていない）。
    @Test func ordinaryWordsAndPartsOfWordsAreKept() {
        #expect(clean("あの人は来ません") == "あの人は来ません")
        #expect(clean("その本を読みます") == "その本を読みます")
        #expect(clean("ええ、そうですね") == "ええ、そうですね")
        #expect(clean("ええー、すごい") == "ええー、すごい")   // 「えー」が、前の「え」に続く：消さない
        #expect(clean("今日はえーと明日") == "今日はえーと明日")   // 前が文字で、直後も、区切りでない：確かでない
    }

    @Test func aFillerOnItsOwnLeavesNothing() {
        #expect(clean("えーと") == "")
        #expect(clean("えーと。") == "")
        #expect(clean("  あのー、 ") == "")
    }

    @Test func aStrayPeriodAfterAFillerThatStartedASentenceGoesToo() {
        #expect(clean("今日は晴れ。えーと。明日は雨") == "今日は晴れ。明日は雨")
    }

    @Test func linesAreKept() {
        #expect(clean("一行目\nえーと、二行目") == "一行目\n二行目")
    }

    /// 実際の Apple の認識結果（自作の合成音声「えーっと、今日は、あのー、いい天気ですね。うーん、えーと、明日は雨でしょうか」）：句読点がないところも、消える。
    @Test func aRealRecognitionResultWithFillers() {
        #expect(clean("えっと、今日はあのいい天気ですね。うーんえーと明日は雨でしょうか") == "今日はあのいい天気ですね。明日は雨でしょうか")
    }

    // MARK: 英語

    @Test func englishFillersAreWholeWordsAndCaseInsensitive() {
        #expect(clean("I um think so") == "I think so")
        #expect(clean("Um, I think so") == "I think so")
        #expect(clean("I think, um, we should") == "I think, we should")
        #expect(clean("I think UH we should") == "I think we should")
        #expect(clean("It is, hmm... fine") == "It is, fine")
    }

    @Test func partsOfEnglishWordsAreKept() {
        #expect(clean("An umbrella") == "An umbrella")
        #expect(clean("uh-huh, right") == "uh-huh, right")
        #expect(clean("the hummus") == "the hummus")
    }

    // MARK: 辞書

    @Test func aCustomListReplacesTheDefaults() {
        #expect(clean("まあ、いいか", ["まあ"]) == "いいか")
        #expect(clean("えーと、いいか", ["まあ"]) == "えーと、いいか")
        #expect(clean("しまあ", ["まあ"]) == "しまあ")   // 2 文字の語は、前が文字のとき、一致しない
        #expect(clean("えーと", []) == "えーと")
    }

    @Test func aLongerWordWinsOverItsPrefix() {
        // 「えーっと」が、「えー」で切られて、「っと」が残らない
        #expect(clean("えーっと、今日は", ["えー", "えーっと"]) == "今日は")
    }

    @Test func newWordsAreCheckedOnce() {
        #expect(FillerWords.normalize("  えーっと  ") == .success("えーっと"))
        #expect(FillerWords.normalize("you   know") == .success("you know"))
        #expect(FillerWords.normalize("") == .failure(.empty))
        #expect(FillerWords.normalize("   ") == .failure(.empty))
        #expect(FillerWords.normalize("あ") == .failure(.tooShort))
        #expect(FillerWords.normalize("なんかを") == .failure(.endsWithParticle))   // 声から取り出した語に、助詞が付いてきた
        #expect(FillerWords.normalize("なんか") == .success("なんか") && FillerWords.normalize("あのさ") == .success("あのさ"))
        #expect(FillerWords.normalize("、、") == .failure(.notAWord))
        #expect(FillerWords.normalize("a\u{0}b") == .failure(.notAWord))
        #expect(FillerWords.normalize(String(repeating: "あ", count: 21)) == .failure(.tooLong))
    }

    /// 濁点を分けた形（実際に、言語モデルが、そう出した）は、1 文字の形にそろえて保存する。同じ語は、重ねて足されない。
    @Test func decomposedKanaIsStoredComposedAndNotAddedTwice() throws {
        let decomposed = "あのて\u{3099}すね"
        #expect(FillerWords.normalize(decomposed) == .success("あのですね"))
        #expect(try FillerWords.adding(decomposed, to: ["あのですね"]).get().added == false)
        #expect(clean("あのですね、今日は", [decomposed]) == "今日は")
    }

    @Test func addingIsIdempotentAndCaseInsensitiveAndRemovingWorks() throws {
        let first = try FillerWords.adding("Hmm", to: ["hmm"]).get()
        #expect(first.added == false && first.list == ["hmm"])
        let second = try FillerWords.adding("あのさ", to: ["hmm"]).get()
        #expect(second.added && second.list == ["hmm", "あのさ"])
        let removed = FillerWords.removing("HMM", from: second.list)
        #expect(removed.removed && removed.list == ["あのさ"])
        #expect(FillerWords.removing("なし", from: ["hmm"]).removed == false)
        #expect(throws: FillerWords.Invalid.tooMany) { try FillerWords.adding("あのさ", to: (0..<FillerWords.maxCount).map { "語\($0)" }).get() }
    }

    @Test func theSettingsDefaultToOffAndTheDefaultList() {
        #expect(FillerWords.isEnabled(setting: nil) == false && FillerWords.isEnabled(setting: true))
        #expect(FillerWords.list(setting: nil) == FillerWords.defaults && FillerWords.list(setting: ["a1"]) == ["a1"])
    }
}

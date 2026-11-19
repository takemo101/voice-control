import Testing
@testable import VCSpeech

/// 英語の文字を、単語のすぐあとに入れるときの空白：足すのは、英数字・文の区切りのあとに、英数字が続くときだけ。
@Suite struct SmartSpacingTests {
    @Test func aSpaceIsAddedAfterAWordOrASentenceEnd() {
        #expect(SmartSpacing.adjusted("world", before: "o") == " world")
        #expect(SmartSpacing.adjusted("Next sentence.", before: ".") == " Next sentence.")
        #expect(SmartSpacing.adjusted("3 items", before: "a") == " 3 items")
        #expect(SmartSpacing.adjusted("then", before: ",") == " then")
        #expect(SmartSpacing.adjusted("x", before: ")") == " x")
        #expect(SmartSpacing.adjusted("x", before: "\"") == " x")
    }

    @Test func nothingIsAddedWhenTheContextIsUnknownOrNotAWord() {
        #expect(SmartSpacing.adjusted("world", before: nil) == "world")      // 読めない・先頭
        #expect(SmartSpacing.adjusted("world", before: " ") == "world")      // すでに空白
        #expect(SmartSpacing.adjusted("world", before: "\n") == "world")     // 行頭
        #expect(SmartSpacing.adjusted("world", before: "(") == "world")      // 開き括弧のあと
        #expect(SmartSpacing.adjusted("world", before: "-") == "world")
        #expect(SmartSpacing.adjusted(" world", before: "o") == " world")    // すでに、空白で始まる
        #expect(SmartSpacing.adjusted(", then", before: "o") == ", then")    // 区切りで始まる
        #expect(SmartSpacing.adjusted("", before: "o") == "")
    }

    @Test func japaneseIsNeverSpaced() {
        #expect(SmartSpacing.adjusted("こんにちは", before: "o") == "こんにちは")    // 入れる文字が日本語
        #expect(SmartSpacing.adjusted("world", before: "あ") == "world")          // 前が日本語：足さない
        #expect(SmartSpacing.adjusted("世界", before: "。") == "世界")
    }
}

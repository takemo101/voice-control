import Foundation
import Testing
@testable import VCPCControl

@Suite struct TextExtractorTests {
    @Test func prefersQuotedText() {
        #expect(TextExtractor.text(in: "「こんにちは」と入力して") == "こんにちは")
        #expect(TextExtractor.text(in: "検索欄に\"hello world\"と打って") == "hello world")
    }

    @Test func fallsBackToTextBeforeTheVerb() {
        #expect(TextExtractor.text(in: "明日の会議と入力して") == "明日の会議")
    }

    @Test func returnsNilWithoutText() {
        #expect(TextExtractor.text(in: "メッセージを送って") == nil)
    }
}

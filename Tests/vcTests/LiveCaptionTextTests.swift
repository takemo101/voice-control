import Testing
@testable import vc

/// 録音中の文字の欄：収まる分だけ出す。切るのは、先頭から（新しい言葉を、残す）。確定前の文字（末尾）は、できるだけ残す。
@Suite struct LiveCaptionTextTests {
    @Test func shortTextIsKeptAsIs() {
        let t = LiveCaptionText(confirmed: "コーデックスに", tentative: "この画面を").tail(maxCharacters: 50)
        #expect(t.confirmed == "コーデックスに" && t.tentative == "この画面を" && !t.truncated)
    }

    @Test func longTextIsCutFromTheStartAndMarkedTruncated() {
        let t = LiveCaptionText(confirmed: "あいうえおかきくけこ", tentative: "さしす").tail(maxCharacters: 8)
        #expect(t.truncated && t.confirmed + t.tentative == "えおかきくけこさしす".suffix(8).description)
        #expect(t.tentative == "さしす")   // 確定前の文字は、残す
        #expect((t.confirmed + t.tentative).count == 8)
    }

    @Test func whenTheTentativeTailAloneIsTooLongItIsCutToo() {
        let t = LiveCaptionText(confirmed: "あ", tentative: "いうえおかきくけこ").tail(maxCharacters: 4)
        #expect(t.confirmed.isEmpty && t.tentative == "きくけこ" && t.truncated)
    }

    @Test func theExactLimitIsNotTruncatedAndEmptyIsEmpty() {
        #expect(!LiveCaptionText(confirmed: "あいうえ", tentative: "").tail(maxCharacters: 4).truncated)
        #expect(LiveCaptionText(confirmed: "", tentative: "").isEmpty && !LiveCaptionText(confirmed: "", tentative: "あ").isEmpty)
    }
}

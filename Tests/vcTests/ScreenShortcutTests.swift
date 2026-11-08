import Testing
import VCSpeech
@testable import vc

/// スクリーンショットのショートカット：長押しは使えない・ほかのキーと重ならない。読み取った文字は、そのまま（Markdown として解釈させず）に出る。
@Suite struct ScreenShortcutTests {
    private func spec(_ text: String) -> HotKeySpec {
        guard case let .success(spec) = HotKeySpec.parse(text) else { fatalError("テストの書き方: \(text)") }
        return spec
    }

    @Test func holdsAndClashesAreRefused() {
        #expect(ScreenKeys.problem(spec("shift"), taken: []) != nil)
        #expect(ScreenKeys.problem(spec("rcmd"), taken: []) != nil)
        #expect(ScreenKeys.problem(spec("ctrl+opt+s"), taken: [("声で頼む", spec("shift")), ("文字の書き出し", spec("ctrl+opt+t"))]) == nil)
        let clash = ScreenKeys.problem(spec("ctrl+opt+t"), taken: [("声で頼む", spec("shift")), ("文字の書き出し", spec("ctrl+opt+t"))])
        #expect(clash?.contains("文字の書き出し") == true)
    }

    @Test func theTranscriptIsFencedSoMarkdownIsNotInterpreted() {
        #expect(TranscriptDocument.markdown("# 見出し\n* 点") == "```\n# 見出し\n* 点\n```\n")
        // 文字の中の ``` で、囲みが閉じないよう、囲みを長くする
        #expect(TranscriptDocument.markdown("```swift\nlet a = 1\n```").hasPrefix("````\n"))
    }
}

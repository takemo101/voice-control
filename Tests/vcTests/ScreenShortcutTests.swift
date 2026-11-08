import Testing
import VCSpeech
@testable import vc

/// スクリーンショットのショートカット：長押しは使えない・ほかのキーと重ならない。
@Suite struct ScreenShortcutTests {
    private func spec(_ text: String) -> HotKeySpec {
        guard case let .success(spec) = HotKeySpec.parse(text) else { fatalError("テストの書き方: \(text)") }
        return spec
    }

    @Test func holdsAndClashesAreRefused() {
        #expect(ScreenKeys.problem(spec("shift"), taken: []) != nil)
        #expect(ScreenKeys.problem(spec("rcmd"), taken: []) != nil)
        #expect(ScreenKeys.problem(spec("ctrl+opt+s"), taken: [("声で頼む", spec("shift")), ("音声入力", spec("ctrl+opt+t"))]) == nil)
        let clash = ScreenKeys.problem(spec("ctrl+opt+t"), taken: [("声で頼む", spec("shift")), ("音声入力", spec("ctrl+opt+t"))])
        #expect(clash?.contains("音声入力") == true)
    }
}

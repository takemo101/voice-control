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

/// キーどうしの重なり：声で頼む・音声入力・スクリーンショットが、重ならない。
@Suite struct KeyConflictsTests {
    private func spec(_ text: String) -> HotKeySpec {
        guard case let .success(spec) = HotKeySpec.parse(text) else { fatalError("テストの書き方: \(text)") }
        return spec
    }

    @Test func noConflictWhenKeysAreDistinct() {
        #expect(KeyConflicts.message(listen: spec("shift"), dictate: spec("ctrl"), shot: spec("ctrl+opt+s")) == nil)
        #expect(KeyConflicts.message(listen: spec("shift"), dictate: nil, shot: nil) == nil)
    }

    @Test func dictateOverlappingListenIsExplainedWithTheFix() {
        let message = KeyConflicts.message(listen: spec("shift"), dictate: spec("rshift"), shot: nil)   // 右 Shift は、左右どちらも指す Shift と重なる
        #expect(message?.contains("vc hotkey set-dictate") == true)
    }

    @Test func aShotKeyThatClashesOrIsAHoldIsRefused() {
        #expect(KeyConflicts.message(listen: spec("shift"), dictate: nil, shot: spec("shift")) != nil)
        #expect(KeyConflicts.message(listen: spec("ctrl+opt+space"), dictate: nil, shot: spec("ctrl+opt+space")) != nil)
    }
}

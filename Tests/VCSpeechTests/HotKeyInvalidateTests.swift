import Carbon.HIToolbox
import Testing
@testable import VCSpeech

/// 設定を変えて作り直すとき、同じキーを、すぐ登録し直せること（外さないと、`register(-9878)`＝登録済み、で失敗した：実際の不具合）。
@MainActor @Suite struct HotKeyInvalidateTests {
    private let modifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)

    @Test func theSameKeyCanBeRegisteredAgainRightAfterInvalidate() throws {
        let first = try HotKey(keyCode: UInt32(kVK_F19), modifiers: modifiers)
        #expect(throws: HotKey.Failure.self) { _ = try HotKey(keyCode: UInt32(kVK_F19), modifiers: self.modifiers) }   // 登録中は、重なる
        first.invalidate()
        let second = try HotKey(keyCode: UInt32(kVK_F19), modifiers: modifiers)   // 手放しを待たずに、登録し直せる
        second.invalidate()
    }
}

import Foundation
import Testing
@testable import VCSpeech
import VCCore

@Suite struct HotKeySpecTests {
    private func parsed(_ text: String) throws -> HotKeySpec { try HotKeySpec.parse(text).get() }
    private func reason(_ text: String) -> String? {
        if case let .failure(f) = HotKeySpec.parse(text) { return f.reason }
        return nil
    }

    @Test func modifierOnlyIsAHold() throws {
        let shift = try parsed("shift")
        #expect(shift.isHold && shift == .default)
        let combo = try parsed("Ctrl + Opt")
        #expect(combo.isHold)
        #expect(combo.description == "ctrl+opt")
    }

    @Test func modifiersPlusKeyIsACombination() throws {
        let spec = try parsed("cmd+shift+R")
        #expect(!spec.isHold)
        #expect(spec.keyCode != nil)
        #expect(spec.description == "shift+cmd+r")  // 正規化：ctrl・opt・shift・cmd の順
    }

    @Test func legacyDashFormAndAliases() throws {
        #expect(try parsed("ctrl-opt-space") == parsed("control+alt+space"))
        #expect(try parsed("cmd+enter") == parsed("command+return"))
    }

    @Test func functionKeyMayStandAlone() throws {
        #expect(try parsed("f5").description == "f5")
    }

    @Test func rejectsWhatWouldStealTyping() {
        #expect(reason("r") != nil)       // 修飾キーなしの文字
        #expect(reason("space") != nil)
        #expect(reason("shift+a+b") != nil)  // キーが 2 つ
        #expect(reason("ctrl+") != nil)
        #expect(reason("") != nil)
        #expect(reason("ctrl+nope") != nil)
    }

    @Test func settingsFallBackToShiftAndReportBadValues() throws {
        var s = Settings()
        #expect(try s.hotkeySpec.get() == .default)
        s.hotkey = "ctrl+opt+space"
        #expect(try s.hotkeySpec.get().description == "ctrl+opt+space")
        s.hotkey = "bogus+"
        #expect(throws: HotKeySpec.Failure.self) { try s.hotkeySpec.get() }
    }

    @Test func oldSettingsFileWithoutHotkeyStillLoads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"disabledSkills":["a"]}"#.utf8).write(to: file)
        let s = try Settings.load(from: file)
        #expect(s.disabledSkills == ["a"] && s.hotkey == nil)
        var next = s
        next.hotkey = "f5"
        try next.save(to: file)
        #expect(try Settings.load(from: file) == next)
    }
}

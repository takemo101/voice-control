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

/// 右側のキーだけ（`rshift`・`rcmd`・`ropt`・`rctrl`）：長押し専用。左右の区別は、デバイス依存のビットで見る。
@Suite struct RightModifierTests {
    private func parsed(_ text: String) throws -> HotKeySpec { try HotKeySpec.parse(text).get() }

    @Test func rightSideKeysAreHoldsThatRoundTrip() throws {
        for (text, modifier) in [("rshift", HotKeySpec.Modifier.shift), ("rcmd", .command), ("ropt", .option), ("rctrl", .control)] {
            let spec = try parsed(text)
            #expect(spec.isHold && spec.side == .right && spec.modifiers == [modifier])
            #expect(spec.description == text)
            #expect(try parsed(spec.description) == spec)   // 保存して読み直しても、同じ
        }
        #expect(try parsed("RCommand") == parsed("rcmd") && parsed("ralt") == parsed("ropt"))
        #expect(try parsed("rshift").displayName.hasPrefix("右⇧"))
    }

    /// 右側の指定は、ほかのキーと組み合わせられない（長押し専用）。左右を問わない `shift` は、今までどおり。
    @Test func rightSideKeysCannotBeCombined() throws {
        for text in ["rshift+a", "rshift+cmd", "rshift+rcmd", "ctrl+rshift+space"] {
            guard case .failure = HotKeySpec.parse(text) else { Issue.record("\(text) を受け付けた"); return }
        }
        #expect(try parsed("shift").side == .any)
    }

    /// 取り合う指定：同じ修飾キーで、左右どちらでもの指定と、右側の指定（`shift` と `rshift`）。別の修飾キー・別の側は、取り合わない。
    @Test func overlapsFindsKeysThatWouldFightOverTheSameKey() throws {
        #expect(try parsed("shift").overlaps(parsed("rshift")) && parsed("rshift").overlaps(parsed("shift")))
        #expect(try parsed("rshift").overlaps(parsed("rshift")))
        #expect(try !parsed("rshift").overlaps(parsed("rcmd")))
        #expect(try !parsed("shift").overlaps(parsed("ctrl")))
        #expect(try !parsed("rshift").overlaps(parsed("f5")))
    }

    private let shift: UInt = 0x20000, command: UInt = 0x100000, control: UInt = 0x40000

    /// 右側の指定は、右のキーだけが押されているときだけ（左を押している間・両方を押している間は、違う）。左右を問わない指定は、どちらでも。
    @Test func theDeviceBitsTellLeftFromRight() {
        let leftShift = shift | 0x2 | 0x100, rightShift = shift | 0x4 | 0x100, bothShift = shift | 0x6 | 0x100
        #expect(ModifierHold.matches(raw: rightShift, modifier: .shift, side: .right))
        #expect(!ModifierHold.matches(raw: leftShift, modifier: .shift, side: .right))
        #expect(!ModifierHold.matches(raw: bothShift, modifier: .shift, side: .right))
        #expect(ModifierHold.matches(raw: leftShift, modifier: .shift, side: .any) && ModifierHold.matches(raw: rightShift, modifier: .shift, side: .any))
        #expect(ModifierHold.matches(raw: command | 0x10, modifier: .command, side: .right))
        #expect(!ModifierHold.matches(raw: command | 0x8, modifier: .command, side: .right))
        #expect(ModifierHold.matches(raw: control | 0x2000, modifier: .control, side: .right))
        #expect(ModifierHold.matches(raw: 0x80000 | 0x40, modifier: .option, side: .right))
    }

    /// ほかの修飾キーを、同時に押していたら、違う（右 Shift ＋ 右 Command は、右 Shift の長押しではない）。何も押していなければ、違う。
    @Test func anotherModifierOrNothingDoesNotMatch() {
        #expect(!ModifierHold.matches(raw: shift | 0x4 | command | 0x10, modifier: .shift, side: .right))
        #expect(!ModifierHold.matches(raw: 0x100, modifier: .shift, side: .right))
    }
}

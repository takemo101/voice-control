import Foundation
import Testing
import VCCore

/// 設定（`Settings`）の既定値と、保存して読み直したときの値。
@Suite struct SettingsTests {
    @Test func skillsAreEnabledByDefaultAndTogglePersistently() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var settings = try Settings.load(from: file)
        #expect(settings.isEnabled("a"))
        settings.setEnabled("b", false); settings.setEnabled("a", false)
        try settings.save(to: file)
        let reloaded = try Settings.load(from: file)
        #expect(!reloaded.isEnabled("a") && !reloaded.isEnabled("b") && reloaded.isEnabled("c"))
        var again = reloaded
        again.setEnabled("a", true)
        #expect(again.isEnabled("a") && !again.isEnabled("b"))
    }
}

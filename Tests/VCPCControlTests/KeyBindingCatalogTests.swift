import Foundation
import Testing
import TestSupport
@testable import VCPCControl

@Suite struct KeyBindingCatalogTests {
    private func load(_ json: String) throws -> KeyBindingCatalog.Loaded {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(json.utf8).write(to: dir.appendingPathComponent("t.json"))
        return KeyBindingCatalog.load(directories: [dir])
    }

    @Test func loadsValidDefinitionsAndReportsInvalidOnes() throws {
        let loaded = try load("""
        [{"id":"a","label":"次の曲","keys":["cmd+right"],"app":"Spotify"},
         {"id":"quit","label":"終了","keys":["cmd+q"]},
         {"id":"bad","label":"x","keys":["a"],"when":"(["},
         {"id":"a","label":"重複","keys":["b"]},
         {"id":"empty","label":"","keys":["a"]}]
        """)
        #expect(loaded.shortcuts.map(\.combo) == ["cmd+right"])
        #expect(loaded.shortcuts.first?.app == "Spotify")
        #expect(loaded.problems.count == 4)
        #expect(loaded.problems.contains { $0.contains("終了") })
    }

    @Test func malformedFileIsReportedNotIgnored() throws {
        #expect(try load("not json").problems.count == 1)
    }

    @Test func appAndPhraseConditionsFilterCandidates() throws {
        let bindings = [Shortcut(combos: ["cmd+right"], option: "次の曲", app: "Spotify"),
                      Shortcut(combos: ["cmd+left"], option: "前の曲", app: "Safari"),
                      Shortcut(combos: ["x"], option: "条件つき", when: "音量")]
        let spy = OptionSpy()
        _ = try Planner(scorer: spy, desktop: StaticDesktop(app: "Spotify"), keyBindings: bindings).plan("曲を進めて")
        #expect(spy.seen.contains("キー操作: 次の曲"))
        #expect(!spy.seen.contains("キー操作: 前の曲"))
        #expect(!spy.seen.contains("キー操作: 条件つき"))
    }
}

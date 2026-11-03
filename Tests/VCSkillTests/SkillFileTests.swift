import Foundation
import Testing
@testable import VCSkill

@Suite struct SkillFileTests {
    @Test func parsesFrontMatterAndBody() throws {
        let skill = try parse("""
        ---
        name: demo
        description: "アプリを開く・起動する"
        allowed-commands:
          - open
          - agent-desktop click
        confirm: true
        ---
        Open the app.
        """).get()
        #expect(skill.name == "demo")
        #expect(skill.description == "アプリを開く・起動する")
        #expect(skill.allowedCommands == ["open", "agent-desktop click"])
        #expect(skill.confirm)
        #expect(skill.body == "Open the app.")
    }

    @Test func acceptsASingleCommandWrittenAsAScalar() throws {
        #expect(try parse("---\nname: demo\ndescription: x\nallowed-commands: open\n---\nbody").get().allowedCommands == ["open"])
    }

    @Test func acceptsInlineListAndDefaultsConfirmToFalse() throws {
        let skill = try parse("---\nname: demo\ndescription: x\nallowed-commands: [open, say]\n---\nbody").get()
        #expect(skill.allowedCommands == ["open", "say"])
        #expect(!skill.confirm)
    }

    @Test func rejectsInvalidFiles() {
        func reason(_ text: String, dir: String = "demo") -> String? { if case .failure(let e) = parse(text, dir: dir) { return e.reason } else { return nil } }
        #expect(reason("no front matter")?.contains("フロントマター") == true)
        #expect(reason("---\nname: demo\ndescription: x\n---\nbody")?.contains("allowed-commands") == true)
        #expect(reason("---\nname: other\ndescription: x\nallowed-commands: [open]\n---\nbody")?.contains("ディレクトリ名") == true)
        #expect(reason("---\nname: Demo\ndescription: x\nallowed-commands: [open]\n---\nbody", dir: "Demo")?.contains("英小文字") == true)
        #expect(reason("---\nname: demo\ndescription: x\nallowed-commands: [bash]\n---\nbody")?.contains("bash") == true)
        #expect(reason("---\nname: demo\ndescription: x\nallowed-commands: [/bin/rm]\n---\nbody")?.contains("パス") == true)
        #expect(reason("---\nname: demo\ndescription: x\nallowed-commands: [open]\n---\n  \n")?.contains("本文") == true)
        #expect(reason("---\nname: demo\ndescription: \(String(repeating: "あ", count: 201))\nallowed-commands: [open]\n---\nbody")?.contains("長い") == true)
    }

    @Test func loadsADirectoryAndReportsBrokenSkillsWithoutHidingTheGoodOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ text: String) throws {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        }
        try write("good", "---\nname: good\ndescription: 良い\nallowed-commands: [open]\n---\nbody")
        try write("bad", "---\nname: bad\ndescription: 悪い\n---\nbody")
        let loaded = SkillStore.load(directory: root)
        #expect(loaded.skills.map(\.name) == ["good"])
        #expect(loaded.problems.map(\.location) == ["bad"])
    }
}

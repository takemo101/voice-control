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

/// `${SKILL_DIR}`：スクリプトを同梱するスキルを、置き場所（グローバル・プロジェクト）に関わらず、同じ SKILL.md で動かす。
@Suite struct SkillDirPlaceholderTests {
    private func load(dir: String) throws -> Skill {
        try SkillStore.parse("""
        ---
        name: demo
        description: x
        allowed-commands:
          - osascript ${SKILL_DIR}/run.applescript
        ---
        Run: osascript ${SKILL_DIR}/run.applescript <action>
        """, directoryName: "demo", file: URL(fileURLWithPath: "\(dir)/demo/SKILL.md")).get()
    }

    @Test func theDirectoryOfTheSkillReplacesThePlaceholderInCommandsAndBody() throws {
        let skill = try load(dir: "/home/u/.voice-control/skills")
        #expect(skill.allowedCommands == ["osascript /home/u/.voice-control/skills/demo/run.applescript"])
        #expect(skill.body == "Run: osascript /home/u/.voice-control/skills/demo/run.applescript <action>")
    }

    /// 置き場所が違っても、同じ SKILL.md で、その場所のスクリプトを指す（グローバルに置いたとき、相対パスで失敗しない）。
    @Test func theSamePlaceholderFollowsTheSkillToWhereverItIsPlaced() throws {
        let a = try load(dir: "/home/u/.voice-control/skills"), b = try load(dir: "/work/proj/.voice-control/skills")
        #expect(a.allowedCommands != b.allowedCommands)
        #expect(b.allowedCommands == ["osascript /work/proj/.voice-control/skills/demo/run.applescript"])
    }

    /// 置き換えたコマンドは、許可の照合を、そのまま通る。空白を含むパスでも、1 つの引数として読まれ、ほかのスクリプトは通らない。
    @Test func theExpandedCommandStillMatchesThePolicyEvenWithSpacesInThePath() throws {
        let skill = try load(dir: "/Users/Some One/.voice-control/skills")
        let script = "/Users/Some One/.voice-control/skills/demo/run.applescript"
        #expect(CommandPolicy.check(argv: ["osascript", script, "play"], allowed: skill.allowedCommands) == nil)
        #expect(CommandPolicy.check(argv: ["osascript", "/tmp/evil.applescript", "play"], allowed: skill.allowedCommands) != nil)
    }

    @Test func aSkillWithoutThePlaceholderIsLeftAsWritten() throws {
        let skill = try parse("---\nname: demo\ndescription: x\nallowed-commands: osascript .voice-control/skills/demo/run.applescript\n---\nbody").get()
        #expect(skill.allowedCommands == ["osascript .voice-control/skills/demo/run.applescript"])
    }
}

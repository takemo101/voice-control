import Foundation
import Testing
@testable import VCSkill
import VCCore

@Suite struct ProjectSkillTests {
    private func skillText(_ name: String, _ description: String) -> String {
        "---\nname: \(name)\ndescription: \(description)\nallowed-commands:\n  - open\n---\nOpen.\n"
    }

    /// 一時ディレクトリに、グローバルとプロジェクトのスキルを置く。
    private func makeRoots(global: [String: String], project: [String: String]) throws -> (global: URL, project: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vc-skills-\(UUID().uuidString)")
        let globalDir = base.appendingPathComponent("home/skills")
        let projectRoot = base.appendingPathComponent("repo")
        for (dir, skills) in [(globalDir, global), (VoiceControlHome.projectSkillsDirectory(root: projectRoot), project)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, description) in skills {
                let skillDir = dir.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
                try Data(skillText(name, description).utf8).write(to: skillDir.appendingPathComponent("SKILL.md"))
            }
        }
        return (globalDir, projectRoot)
    }

    @Test func untrustedProjectSkillsAreNotLoaded() throws {
        let roots = try makeRoots(global: ["open-app": "global"], project: ["evil": "from a repo"])
        defer { try? FileManager.default.removeItem(at: roots.project.deletingLastPathComponent()) }

        let loaded = SkillStore.loadAll(projectRoot: roots.project, settings: Settings(), globalDirectory: roots.global)
        #expect(loaded.skills.map(\.name) == ["default", "open-app"])
        #expect(loaded.untrustedProjectCount == 1)
        #expect(loaded.projectDirectory != nil)
    }

    @Test func trustedProjectSkillsLoadAndOverrideGlobalOnes() throws {
        let roots = try makeRoots(global: ["open-app": "global", "only-global": "g"], project: ["open-app": "project", "only-project": "p"])
        defer { try? FileManager.default.removeItem(at: roots.project.deletingLastPathComponent()) }
        var settings = Settings()
        settings.setTrusted(project: roots.project, true)

        let loaded = SkillStore.loadAll(projectRoot: roots.project, settings: settings, globalDirectory: roots.global)
        #expect(loaded.skills.map(\.name) == ["default", "only-global", "only-project", "open-app"])
        let open = try #require(loaded.skills.first { $0.name == "open-app" })
        #expect(open.description == "project" && open.scope == .project)  // 同じ名前は、プロジェクトが勝つ
        #expect(loaded.skills.first { $0.name == "only-global" }?.scope == .global)
        #expect(loaded.overridden == ["open-app"])
        #expect(loaded.untrustedProjectCount == 0)
    }

    @Test func trustIsPerProjectAndCanBeRevoked() throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("vc-proj-a-\(UUID().uuidString)")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("vc-proj-b-\(UUID().uuidString)")
        var settings = Settings()
        settings.setTrusted(project: a, true)
        #expect(settings.isTrusted(project: a))
        #expect(!settings.isTrusted(project: b))
        settings.setTrusted(project: a, false)
        #expect(!settings.isTrusted(project: a))
    }

    @Test func projectDirectoryThatIsTheGlobalOneIsNotLoadedTwice() throws {
        // ホームで起動したとき：<ホーム>/.voice-control/skills が、グローバルと同じ場所になる
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-home-\(UUID().uuidString)")
        let global = VoiceControlHome.projectSkillsDirectory(root: root)
        try FileManager.default.createDirectory(at: global.appendingPathComponent("open-app"), withIntermediateDirectories: true)
        try Data(skillText("open-app", "g").utf8).write(to: global.appendingPathComponent("open-app/SKILL.md"))
        defer { try? FileManager.default.removeItem(at: root) }

        let loaded = SkillStore.loadAll(projectRoot: root, settings: Settings(), globalDirectory: global)
        #expect(loaded.skills.count == 2 && loaded.projectDirectory == nil && loaded.untrustedProjectCount == 0)
    }

    @Test func oldSettingsWithoutTrustedProjectsStillLoad() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"disabledSkills":[],"hotkey":"f5"}"#.utf8).write(to: file)
        let settings = try Settings.load(from: file)
        #expect(settings.trustedProjects.isEmpty && settings.hotkey == "f5")
    }
}

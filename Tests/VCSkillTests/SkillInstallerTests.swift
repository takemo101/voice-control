import Foundation
import Testing
@testable import VCSkill

/// プロジェクトのスキルを、グローバルへコピーする（`vc skills install`）。
@Suite struct SkillInstallerTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `<root>/<name>/SKILL.md` と、同梱のスクリプト。
    @discardableResult
    private func makeSkill(_ root: URL, _ name: String, command: String = "osascript ${SKILL_DIR}/run.applescript", script: String = "v1", body: String = "Run it.") throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: x\nallowed-commands:\n  - \(command)\n---\n\(body)".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try script.write(to: dir.appendingPathComponent("run.applescript"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func copiesTheWholeSkillDirectoryAndTheCommandPointsAtTheNewPlace() throws {
        let project = try temp(), global = try temp()
        try makeSkill(project, "demo")
        let result = try SkillInstaller.install(name: "demo", from: project, to: global, overwrite: false)
        #expect(try String(contentsOf: global.appendingPathComponent("demo/run.applescript"), encoding: .utf8) == "v1")
        #expect(result.allowedCommands == ["osascript \(global.appendingPathComponent("demo").path)/run.applescript"])
        #expect(!result.overwritten && !result.usesProjectRelativePath)
        #expect(SkillStore.load(directory: global).skills.map(\.name) == ["demo"])   // グローバルのスキルとして読める
    }

    @Test func anExistingSkillIsKeptUnlessOverwritingAndOldFilesDoNotRemain() throws {
        let project = try temp(), global = try temp()
        try makeSkill(project, "demo", script: "new")
        let old = try makeSkill(global, "demo", script: "old")
        try "stale".write(to: old.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        #expect(throws: SkillInstaller.Failure.alreadyInstalled("demo")) { try SkillInstaller.install(name: "demo", from: project, to: global, overwrite: false) }
        #expect(try String(contentsOf: old.appendingPathComponent("run.applescript"), encoding: .utf8) == "old")   // 触らない
        let result = try SkillInstaller.install(name: "demo", from: project, to: global, overwrite: true)
        #expect(result.overwritten)
        #expect(try String(contentsOf: old.appendingPathComponent("run.applescript"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("stale.txt").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: global.path) == ["demo"])   // 一時の場所が、残らない
    }

    @Test func aMissingOrBrokenSkillOrAPathLikeNameCopiesNothing() throws {
        let project = try temp(), global = try temp()
        try makeSkill(project, "good")
        let broken = project.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "no front matter".write(to: broken.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        #expect(throws: SkillInstaller.Failure.notFound("nope")) { try SkillInstaller.install(name: "nope", from: project, to: global, overwrite: false) }
        #expect(throws: SkillInstaller.Failure.notFound("../good")) { try SkillInstaller.install(name: "../good", from: project, to: global, overwrite: false) }
        do { _ = try SkillInstaller.install(name: "broken", from: project, to: global, overwrite: false); Issue.record("読めないスキルが、コピーされた") }
        catch let SkillInstaller.Failure.unreadable(name, _) { #expect(name == "broken") }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: global.path))?.isEmpty ?? true)
    }

    @Test func aSkillWithASymbolicLinkIsRefused() throws {
        let project = try temp(), global = try temp()
        let dir = try makeSkill(project, "demo")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: SkillInstaller.Failure.containsSymlink(name: "demo", path: "link")) { try SkillInstaller.install(name: "demo", from: project, to: global, overwrite: false) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: global.path))?.isEmpty ?? true)
    }

    /// 相対パス（`.voice-control/skills/…`）で書いたスキルは、グローバルでは動かない恐れがある：コピーはするが、知らせる。
    @Test func aProjectRelativePathIsReported() throws {
        let project = try temp(), global = try temp()
        try makeSkill(project, "demo", command: "osascript .voice-control/skills/demo/run.applescript")
        #expect(try SkillInstaller.install(name: "demo", from: project, to: global, overwrite: false).usesProjectRelativePath)
    }
}

import Foundation
import Testing
import TestSupport
@testable import VCSkill
import VCCore
import VCDecision

@Suite struct DefaultSkillTests {
    @Test func builtInDefaultSkillHasOnlyValidModestPermissions() {
        for entry in DefaultSkill.allowedCommands { #expect(CommandPolicy.validateEntry(entry) == nil, "\(entry)") }
        // 削除・移動・通信・任意のスクリプトは、既定では許可しない
        for risky in ["rm", "mv", "curl", "osascript", "sh", "bash", "sudo", "git"] {
            #expect(!DefaultSkill.allowedCommands.contains(risky), "\(risky)")
        }
        #expect(DefaultSkill.allowedCommands.contains("agent-desktop"))
    }

    @Test func loadAllAddsTheBuiltInDefaultUnlessTheUserDefinesOne() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vc-default-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("skills")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let builtin = SkillStore.loadAll(projectRoot: nil, settings: Settings(), globalDirectory: dir)
        #expect(builtin.skills.map(\.name) == ["default"] && builtin.skills[0].scope == .builtin)

        let custom = dir.appendingPathComponent("default")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Data("---\nname: default\ndescription: mine\nallowed-commands:\n  - git status\n---\nDo it.\n".utf8).write(to: custom.appendingPathComponent("SKILL.md"))
        let overridden = SkillStore.loadAll(projectRoot: nil, settings: Settings(), globalDirectory: dir)
        #expect(overridden.skills.count == 1 && overridden.skills[0].allowedCommands == ["git status"] && overridden.skills[0].scope == .global)
    }

    @Test func aMatchingSkillWinsAndDefaultIsNeverARouterOption() throws {
        let spotify = skill("spotify", "Spotify の操作")
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: "Spotify の操作"), skills: [DefaultSkill.skill, spotify], gate: Gate())
        guard case let .resolved(r) = try resolver.resolve("次の曲") else { Issue.record("not resolved"); return }
        #expect(r.skill.name == "spotify" && r.kind == .matched && r.confirmReason == nil)
    }

    @Test func noMatchFallsBackToDefaultWhenItIsAnActionableRequest() throws {
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: nil), skills: [DefaultSkill.skill, skill("spotify", "Spotify の操作")], gate: Gate())
        guard case let .resolved(r) = try resolver.resolve("電卓を開いて") else { Issue.record("not resolved"); return }
        #expect(r.skill.name == "default" && r.kind == .fallback && r.confirmReason == nil)
    }

    @Test func conversationIsNotSentToTheDefaultSkill() throws {
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: nil, actionable: 0.01), skills: [DefaultSkill.skill], gate: Gate())
        guard case let .declined(reason, available) = try resolver.resolve("ちょっと待ってね") else { Issue.record("resolved"); return }
        #expect(available && reason.contains("操作の依頼ではない"))
    }

    @Test func riskyRequestsAskForConfirmationOnTheFallback() throws {
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: nil, destructive: 0.9), skills: [DefaultSkill.skill], gate: Gate())
        guard case let .resolved(r) = try resolver.resolve("ファイルを全部削除して") else { Issue.record("not resolved"); return }
        #expect(r.kind == .fallback && r.confirmReason != nil)
    }

    @Test func withoutADefaultSkillNothingFallsBack() throws {
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: nil), skills: [skill("spotify", "Spotify の操作")], gate: Gate())
        guard case let .declined(_, available) = try resolver.resolve("電卓を開いて") else { Issue.record("resolved"); return }
        #expect(!available)  // 既定スキルがないので、何も実行しない
    }

    @Test func lowConfidenceMatchStillConfirms() throws {
        var gate = Gate()
        gate.execute = 0.99
        let spotify = skill("spotify", "Spotify の操作")
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: "Spotify の操作"), skills: [spotify], gate: gate)
        guard case let .resolved(r) = try resolver.resolve("次の曲") else { Issue.record("not resolved"); return }
        #expect(r.confirmReason != nil)
    }
}

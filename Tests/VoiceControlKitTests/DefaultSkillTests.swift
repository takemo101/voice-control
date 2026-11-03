import Foundation
import Testing
@testable import VoiceControlKit

/// 質問ごとに、決めた確率を返す偽物（スキルの選択・操作の依頼か・取り消しにくいか）。
private struct ScriptedScorer: OptionScorer {
    /// スキルの選択で、勝たせる選択肢（説明の文字列）。`nil` なら「どれでもない」（最後の選択肢）。
    var routedDescription: String?
    var actionable = 0.9
    var destructive = 0.1

    func score(state: String, question: String, options: [String]) throws -> [Double] {
        if question.hasPrefix("この発話は、どちらか") { return [1 - actionable, actionable] }
        if question.hasPrefix("この依頼は、削除") { return [1 - destructive, destructive] }
        var p = options.map { _ in 0.01 }
        p[routedDescription.flatMap { options.firstIndex(of: $0) } ?? options.count - 1] = 0.9
        let sum = p.reduce(0, +)
        return p.map { $0 / sum }
    }
}

@Suite struct DefaultSkillTests {
    private func skill(_ name: String, _ description: String, confirm: Bool = false) -> Skill {
        Skill(name: name, description: description, allowedCommands: ["open"], confirm: confirm, body: "x", file: URL(fileURLWithPath: "/tmp/\(name)/SKILL.md"))
    }

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
        let resolver = SkillResolver(scorer: ScriptedScorer(routedDescription: "Spotify の操作"), skills: [DefaultSkill.skill, spotify], gate: Gate())
        guard case let .resolved(r) = try resolver.resolve("次の曲") else { Issue.record("not resolved"); return }
        #expect(r.skill.name == "spotify" && r.kind == .matched && r.confirmReason == nil)
    }

    @Test func noMatchFallsBackToDefaultWhenItIsAnActionableRequest() throws {
        let resolver = SkillResolver(scorer: ScriptedScorer(routedDescription: nil), skills: [DefaultSkill.skill, skill("spotify", "Spotify の操作")], gate: Gate())
        guard case let .resolved(r) = try resolver.resolve("電卓を開いて") else { Issue.record("not resolved"); return }
        #expect(r.skill.name == "default" && r.kind == .fallback && r.confirmReason == nil)
    }

    @Test func conversationIsNotSentToTheDefaultSkill() throws {
        let resolver = SkillResolver(scorer: ScriptedScorer(routedDescription: nil, actionable: 0.01), skills: [DefaultSkill.skill], gate: Gate())
        guard case let .declined(reason, available) = try resolver.resolve("ちょっと待ってね") else { Issue.record("resolved"); return }
        #expect(available && reason.contains("操作の依頼ではない"))
    }

    @Test func riskyRequestsAskForConfirmationOnTheFallback() throws {
        let resolver = SkillResolver(scorer: ScriptedScorer(routedDescription: nil, destructive: 0.9), skills: [DefaultSkill.skill], gate: Gate())
        guard case let .resolved(r) = try resolver.resolve("ファイルを全部削除して") else { Issue.record("not resolved"); return }
        #expect(r.kind == .fallback && r.confirmReason != nil)
    }

    @Test func withoutADefaultSkillNothingFallsBack() throws {
        let resolver = SkillResolver(scorer: ScriptedScorer(routedDescription: nil), skills: [skill("spotify", "Spotify の操作")], gate: Gate())
        guard case let .declined(_, available) = try resolver.resolve("電卓を開いて") else { Issue.record("resolved"); return }
        #expect(!available)  // 呼び出し側が、従来の PC 操作へ回せる
    }

    @Test func lowConfidenceMatchStillConfirms() throws {
        var gate = Gate()
        gate.execute = 0.99
        let spotify = skill("spotify", "Spotify の操作")
        let resolver = SkillResolver(scorer: ScriptedScorer(routedDescription: "Spotify の操作"), skills: [spotify], gate: gate)
        guard case let .resolved(r) = try resolver.resolve("次の曲") else { Issue.record("not resolved"); return }
        #expect(r.confirmReason != nil)
    }
}

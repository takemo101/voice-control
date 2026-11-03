import Foundation
import Testing
@testable import VCSkill
import VCCore
import VCDecision
@testable import VCSpeech

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

private func parse(_ text: String, dir: String = "demo") -> Result<Skill, SkillStore.ParseError> {
    SkillStore.parse(text, directoryName: dir, file: URL(fileURLWithPath: "/tmp/SKILL.md"))
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
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

@Suite struct CommandPolicyTests {
    private let allowed = ["open", "agent-desktop click", "agent-desktop snapshot"]

    @Test func tokenizesLikeAShellWithoutRunningOne() throws {
        #expect(try CommandPolicy.tokenize(#"open -a "Google Chrome""#).get() == ["open", "-a", "Google Chrome"])
        #expect(try CommandPolicy.tokenize("say 'a b' c\\ d").get() == ["say", "a b", "c d"])
        // シェルの記号は、ただの文字：実行されない
        #expect(try CommandPolicy.tokenize("open -a Safari; rm -rf /").get() == ["open", "-a", "Safari;", "rm", "-rf", "/"])
        #expect(throws: CommandPolicy.Violation.self) { try CommandPolicy.tokenize("open 'x").get() }
    }

    @Test func allowsOnlyCommandsMatchingAnAllowedPrefix() {
        #expect(CommandPolicy.check(argv: ["open", "-a", "Safari"], allowed: allowed) == nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "click", "@a1:e3"], allowed: allowed) == nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "type", "@a1:e3", "x"], allowed: allowed) != nil)   // サブコマンドが違う
        #expect(CommandPolicy.check(argv: ["rm", "-rf", "/"], allowed: allowed) != nil)
        #expect(CommandPolicy.check(argv: [], allowed: allowed) != nil)
    }

    @Test func neverAllowsShellsPathsOrForce() {
        #expect(CommandPolicy.check(argv: ["bash", "-c", "ls"], allowed: ["bash"]) != nil)
        #expect(CommandPolicy.check(argv: ["env", "rm"], allowed: ["env"]) != nil)
        #expect(CommandPolicy.check(argv: ["/usr/bin/open", "x"], allowed: ["open"]) != nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "press", "cmd+q", "--force"], allowed: ["agent-desktop"]) != nil)
        #expect(CommandPolicy.validateEntry("sudo") != nil)
        #expect(CommandPolicy.validateEntry("agent-desktop click") == nil)
    }
}

@Suite struct OutputCompactorTests {
    private let snapshot = #"""
    {"ok":true,"data":{"app":"Fixture","tree":{"role":"window","children":[
      {"role":"button","name":"Save","ref_id":"@s17tb038elj2nz:e1","available_actions":["Click"]},
      {"role":"button","name":"Off","ref_id":"@s17tb038elj2nz:e2","available_actions":["Click"],"states":["disabled"]},
      {"role":"group","ref_id":"@s17tb038elj2nz:e3"},
      {"role":"textfield","name":"Search","ref_id":"@s17tb038elj2nz:e4","available_actions":["TypeText"],"states":["focused"]}]}}}
    """#

    @Test func snapshotBecomesShortOperableLinesWithAliasedRefs() {
        let aliases = RefAliases()
        let text = OutputCompactor.compact(argv: ["agent-desktop", "snapshot", "-i"], output: snapshot, aliases: aliases)
        #expect(text == "app: Fixture\n@a1:e1 [button] Save\n@a1:e4 [textfield] Search (focused)")
        // 別名は、実行の直前に、元の参照に戻る
        #expect(aliases.expand("@a1:e4") == "@s17tb038elj2nz:e4")
        #expect(aliases.expand("@zzz:e4") == "@zzz:e4")
        #expect(aliases.expand("Settings") == "Settings")
    }

    @Test func errorsKeepTheirCodeAndLongOutputIsCut() {
        let error = #"{"ok":false,"error":{"code":"STALE_REF","message":"gone"}}"#
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "click", "@a1:e1"], output: error) == "error STALE_REF: gone")
        let long = String(repeating: "x", count: OutputCompactor.maxChars + 50)
        #expect(OutputCompactor.compact(argv: ["ls"], output: long).contains("50 文字を省略"))
    }
}

@Suite struct AllowedCommandsSyntaxTests {
    @Test func normalizesClaudeCodeStyleEntries() throws {
        #expect(try CommandPolicy.normalize("Bash(open -a *)").get() == ["open", "-a"])
        #expect(try CommandPolicy.normalize("Bash(ls:*)").get() == ["ls"])
        #expect(try CommandPolicy.normalize("agent-desktop click *").get() == ["agent-desktop", "click"])
        #expect(try CommandPolicy.normalize("Bash(open -a Spotify)").get() == ["open", "-a", "Spotify"])
        #expect(throws: CommandPolicy.Violation.self) { try CommandPolicy.normalize("Read(./.env)").get() }
        #expect(throws: CommandPolicy.Violation.self) { try CommandPolicy.normalize("Bash(*)").get() }
    }

    @Test func wildcardInsideATokenMatchesOnlyThatToken() {
        let allowed = ["agent-desktop click @a*", "open -a *.app"]
        #expect(CommandPolicy.check(argv: ["agent-desktop", "click", "@a1:e3"], allowed: allowed) == nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "click", "@s1:e3"], allowed: allowed) != nil)   // 本物の参照の形は、通さない
        #expect(CommandPolicy.check(argv: ["open", "-a", "Safari.app"], allowed: allowed) == nil)
        #expect(CommandPolicy.check(argv: ["open", "-a", "Safari"], allowed: allowed) != nil)
    }

    @Test func aStandaloneStarInTheMiddleMatchesExactlyOneToken() {
        let allowed = ["agent-desktop * @a1:e1"]
        #expect(CommandPolicy.check(argv: ["agent-desktop", "click", "@a1:e1"], allowed: allowed) == nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "@a1:e1"], allowed: allowed) != nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "click", "@a1:e2"], allowed: allowed) != nil)
    }

    @Test func prefixSemanticsAreUnchangedAndShellTricksStillFail() {
        // `*` のない項目は、前方一致のまま（Claude Code の「完全一致」とは違う）。末尾の `*` は、あってもなくても同じ。
        #expect(CommandPolicy.check(argv: ["open", "-a", "Safari"], allowed: ["open"]) == nil)
        #expect(CommandPolicy.check(argv: ["open", "-a", "Safari"], allowed: ["Bash(open *)"]) == nil)
        #expect(CommandPolicy.check(argv: ["timeout", "30", "open", "x"], allowed: ["open"]) != nil)   // ラッパーは外さない
        #expect(CommandPolicy.check(argv: ["open", "x;", "rm"], allowed: ["open"]) == nil)             // `;` は、ただの引数
    }

    @Test func entriesThatWouldWidenThePermissionAreRejectedAtLoadTime() {
        #expect(CommandPolicy.validateEntry("* --version") != nil)       // コマンド名の `*`
        #expect(CommandPolicy.validateEntry("Bash(sudo *)") != nil)      // 禁止コマンド
        #expect(CommandPolicy.validateEntry("Read(./x)") != nil)         // Bash 以外のツール
        #expect(CommandPolicy.validateEntry("Bash(open -a *)") == nil)
    }

    @Test func skillFilesAcceptTheBashWrappedForm() throws {
        let skill = try parse("---\nname: demo\ndescription: x\nallowed-commands:\n  - Bash(open -a *)\n  - Bash(agent-desktop click @a*)\n---\nbody").get()
        #expect(skill.allowedCommands == ["Bash(open -a *)", "Bash(agent-desktop click @a*)"])
    }
}

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

@Suite struct CancellationTests {
    @Test func tokenRunsHandlersOnceAndImmediatelyWhenAlreadyCancelled() {
        let token = CancelToken()
        let calls = LockedCounter()
        token.onCancel { calls.increment() }
        #expect(!token.isCancelled)
        token.cancel()
        token.cancel()
        #expect(token.isCancelled && calls.value == 1)
        token.onCancel { calls.increment() }   // 取りやめ済みなら、すぐ呼ぶ
        #expect(calls.value == 2)
    }

    @Test func cancelStopsARunningCommandQuickly() async throws {
        let token = CancelToken()
        let started = Date()
        let canceller = Task { try await Task.sleep(nanoseconds: 300_000_000); token.cancel() }
        let result = await Task.detached { CommandRunner.run(argv: ["sleep", "20"], timeout: 30, cancel: token) }.value
        _ = try await canceller.value
        #expect(result.exitCode == 130 && !result.timedOut)
        #expect(Date().timeIntervalSince(started) < 5)   // 20 秒は待たない
    }

    @Test func aCancelledTokenPreventsTheCommandFromStarting() {
        let token = CancelToken()
        token.cancel()
        let result = CommandRunner.run(argv: ["echo", "should-not-run"], cancel: token)
        #expect(result.exitCode == 130 && !result.output.contains("should-not-run"))
    }

    @Test func discardedRecordingLeavesNoFileAndNoError() throws {
        let session = RecordingSession()
        session.discard()   // 録音していなくても、何も起きない
        #expect(try session.stop() == nil)
    }
}

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

    @Test func routerOffersOnlyTheSkillsItIsGiven() throws {
        final class Spy: OptionScorer, @unchecked Sendable {
            var seen: [String] = []
            func score(state: String, question: String, options: [String]) throws -> [Double] { seen += options; return options.map { _ in 1.0 / Double(options.count) } }
        }
        func skill(_ n: String) -> Skill { Skill(name: n, description: "説明 \(n)", allowedCommands: ["open"], confirm: false, body: "b", file: URL(fileURLWithPath: "/tmp/x")) }
        let spy = Spy()
        _ = try SkillRouter(scorer: spy, skills: [skill("a")]).route("依頼")
        #expect(spy.seen.contains("説明 a") && !spy.seen.contains("説明 b"))
        #expect(try SkillRouter(scorer: spy, skills: []).route("依頼").skill == nil)
    }
}

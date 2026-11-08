import Foundation
import TestSupport
import Testing
@testable import VCSkill

/// スキルの `external`（発話を、この Mac の外へ送る先）と、`vc skills install --all`（リポジトリの、すべてのスキルを置く）。
@Suite struct SkillExternalAndInstallAllTests {
    private func parse(_ front: String) -> Skill? {
        try? SkillStore.parse("---\nname: demo\ndescription: x\nallowed-commands: echo\n\(front)---\nbody", directoryName: "demo", file: URL(fileURLWithPath: "/tmp/demo/SKILL.md")).get()
    }

    /// 書かなければ、送らない（nil）。書けば、その文字。空は、書かないのと同じ。
    @Test func externalIsNilUnlessWritten() {
        #expect(parse("")?.external == nil)
        #expect(parse("external: Google（agy）\n")?.external == "Google（agy）")
        #expect(parse("external:\n")?.external == nil)
    }

    /// 外へ送る断り書き：発話を、送り先へ。送り先がなければ、何も送らない（nil）。
    @Test func theNoticeSaysWhatIsSentWhere() {
        #expect(parse("external: Google（agy）\n")?.externalNotice == "発話を、Google（agy） へ送ります")
        #expect(parse("")?.externalNotice == nil)
    }

    /// 偽のリポジトリ：スキル 2 つ（`alpha`・`beta`〔external つき〕）と、読めないもの（`broken`）。
    private final class Repo: @unchecked Sendable {
        private let lock = NSLock(); private(set) var refs: [String] = []
        let files: [String: String] = [
            ".voice-control/skills/alpha/SKILL.md": "---\nname: alpha\ndescription: a\nallowed-commands: echo\n---\nRun.",
            ".voice-control/skills/beta/SKILL.md": "---\nname: beta\ndescription: b\nallowed-commands: echo\nexternal: どこか\n---\nRun.",
            ".voice-control/skills/broken/SKILL.md": "フロントマターがない",
        ]
        var fetch: RemoteSkills.Fetch {
            { [self] url in
                if url.host == "api.github.com" {
                    let ref = url.pathComponents.last ?? ""
                    lock.lock(); refs.append(ref); lock.unlock()
                    guard ref == "main" else { return (Data(), 404) }   // タグは、ない：main に切り替わる
                    let tree = files.keys.sorted().map { ["path": $0, "mode": "100644", "type": "blob", "size": 10] as [String: Any] }
                    return (try JSONSerialization.data(withJSONObject: ["tree": tree]), 200)
                }
                let path = files.keys.first { url.absoluteString.hasSuffix($0) } ?? ""
                return (Data((files[path] ?? "").utf8), 200)
            }
        }
    }

    /// すべてのスキルを置く：読めないものは、置かず、`problems` に出す。タグがなく、main に切り替えても、一覧と置くものは、同じ版（main）。
    @Test func installAllPlacesEveryReadableSkillFromTheSameRef() async throws {
        let repo = Repo()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ia-\(UUID().uuidString)")
        let (report, problems) = try await RemoteInstall.installAll(explicitRef: nil, defaultRef: "v9.9.9", overwrite: false, to: dir, fetch: repo.fetch)
        #expect(report.source == .init(ref: "main", fellBackToMain: true))
        #expect(report.outcomes.map(\.name) == ["alpha", "beta"])
        let installed = report.outcomes.compactMap { try? $0.result.get() }
        #expect(installed.count == 2 && installed.first { $0.name == "beta" }?.external == "どこか" && installed.first { $0.name == "alpha" }?.external == nil)
        #expect(problems.count == 1 && FileManager.default.fileExists(atPath: dir.appendingPathComponent("alpha/SKILL.md").path) && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("broken").path))
        // 1 回目の一覧で、v9.9.9 → main。置くときは、main を指定する（もう一度、v9.9.9 を試さない）
        #expect(repo.refs.filter { $0 == "v9.9.9" }.count == 1)
    }

    /// すでにあるものは、`--force` なしでは、置き換えず、結果に出る（ほかは、置く）。
    @Test func installAllReportsExistingSkillsAndStillPlacesTheRest() async throws {
        let repo = Repo()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ia-\(UUID().uuidString)")
        _ = try await RemoteInstall.install(names: ["alpha"], explicitRef: "main", defaultRef: "main", overwrite: false, to: dir, fetch: repo.fetch)
        let (report, _) = try await RemoteInstall.installAll(explicitRef: nil, defaultRef: "main", overwrite: false, to: dir, fetch: repo.fetch)
        guard case .failure(.alreadyInstalled("alpha")) = report.outcomes[0].result, case .success = report.outcomes[1].result else { Issue.record("結果が違う"); return }
    }
}

/// `confirm-when`：依頼の文が、条件に合うときだけ、確認する（コードが決める）。合わなければ、確認しない。確認の文は、何を・どこへ送るかを言う。
@Suite struct ConfirmWhenTests {
    private func parse(_ front: String) -> Result<Skill, SkillStore.ParseError> {
        SkillStore.parse("---\nname: demo\ndescription: x\nallowed-commands: echo\n\(front)---\nbody", directoryName: "demo", file: URL(fileURLWithPath: "/tmp/demo/SKILL.md"))
    }

    @Test func onlyMatchingRequestsNeedAConfirmation() throws {
        let skill = try parse("confirm-when: 画面|画像|(?i:screenshot)\nconfirm-sends: 撮った画面の画像と質問\nexternal: OpenAI（codex）\n").get()
        #expect(skill.needsConfirmation(for: "この画面をコーデックスに見せて") && skill.needsConfirmation(for: "see this Screenshot"))
        #expect(!skill.needsConfirmation(for: "Rust の所有権を調べて"))
        #expect(skill.confirmReason(for: "この画面を見せて") == "撮った画面の画像と質問を、OpenAI（codex） へ送ります。実行の前に確認します")
    }

    @Test func confirmTrueAlwaysConfirmsAndSaysUtterance() throws {
        let skill = try parse("confirm: true\nconfirm-when: 画面\nconfirm-sends: 画像\nexternal: どこか\n").get()
        #expect(skill.needsConfirmation(for: "なんでも"))
        #expect(skill.confirmReason(for: "なんでも") == "発話を、どこか へ送ります。実行の前に確認します")   // いつも確認するスキルは、発話を送る前提の文
        let local = try parse("confirm: true\n").get()
        #expect(local.confirmReason(for: "x") == SkillResolver.confirmRequiredReason)
        #expect(try !parse("").get().needsConfirmation(for: "画面"))
    }

    @Test func anUnreadableRegexFailsToLoadWithAReason() {
        guard case let .failure(error) = parse("confirm-when: (\n") else { Issue.record("読み込みに失敗するはず"); return }
        #expect(error.reason.contains("confirm-when"))
    }

    /// 実行の流れ：条件に合う依頼は、確認を挟み、承認されたときだけ、実行者に「確認を通った」と伝わる。断られたら、実行者を作らない。合わない依頼は、確認なし・伝えない。
    @Test func theRunnerAsksOnlyForMatchingRequestsAndTellsTheExecutor() async throws {
        var s = skill("ask", "調べる"); s.confirmWhen = "画面"; s.external = "どこか"; s.confirmSends = "画像"
        func run(_ request: String, approve: Bool) async throws -> (reasons: [String], factory: Factory, outcome: RunOutcome) {
            let factory = Factory(), reporter = Recorder()
            let outcome = try await SkillRunner(selection: .forced(s), dryRun: false, makeExecutor: factory.factory).run(request, reporter: reporter, confirm: { approve })
            return (reporter.events.compactMap { if case let .confirmRequired(_, reason) = $0 { reason } else { nil } }, factory, outcome)
        }
        let yes = try await run("この画面を見せて", approve: true)
        #expect(yes.reasons == ["画像を、どこか へ送ります。実行の前に確認します"] && yes.factory.made.first?.executor.wasConfirmed == true)
        let no = try await run("この画面を見せて", approve: false)
        #expect(no.factory.count == 0)
        let plain = try await run("Rust を調べて", approve: true)
        #expect(plain.reasons.isEmpty && plain.factory.made.first?.executor.wasConfirmed == false)
    }

    /// 外のコマンドが受ける環境変数：確認を通ったかを、コードが伝える（言語モデルは、渡せない）。
    @Test func theCommandSeesWhetherTheRunWasConfirmed() {
        let s = Skill(name: "env", description: "x", allowedCommands: ["printenv"], confirm: false, body: "x", file: URL(fileURLWithPath: "/tmp/env/SKILL.md"))
        func output(confirmed: Bool) -> String {
            let box = Collected<String>()
            let session = CommandSession(skill: s, dryRun: false, display: ExecutionDisplay(onCommand: { _ in }, onResult: { _, text in box.add(text) }, onDenied: { _, _ in }), cancel: nil)
            if confirmed { session.markConfirmed() }
            _ = session.execute("printenv VC_CONFIRMED")
            return box.values.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        #expect(output(confirmed: false) == "0" && output(confirmed: true) == "1")
    }
}

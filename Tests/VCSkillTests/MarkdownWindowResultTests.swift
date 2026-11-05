import Foundation
import TestSupport
import Testing
@testable import VCSkill

/// `result: markdown-window`：最後の返事（Markdown の本文）は、結果（`document`）として渡り、返事は `done: …` になる。失敗の返事・dry-run は、ウィンドウに出さない。
@Suite struct MarkdownWindowResultTests {
    private func windowSkill() -> Skill { var s = skill("note", "x"); s.result = .markdownWindow; return s }

    private func run(_ skill: Skill, dryRun: Bool = false, reply: String) async throws -> Recorder {
        let reporter = Recorder()
        _ = try await SkillRunner(selection: .forced(skill), dryRun: dryRun, makeExecutor: Factory(script: { _ in reply }).factory).run("x", reporter: reporter, confirm: { false })
        return reporter
    }

    @Test func theBodyIsPassedAsTheDocumentAndTheReplyIsShort() async throws {
        let reporter = try await run(windowSkill(), reply: "# 題\n\n本文")
        #expect(reporter.kinds == ["forced", "started", "document", "reply"])
        guard case let .document(markdown) = reporter.events[2], case let .reply(reply, _, _) = reporter.events[3] else { Issue.record("順序が違う"); return }
        #expect(markdown == "# 題\n\n本文")
        #expect(reply == "done: 結果をウィンドウに表示しました")
    }

    @Test func aFailedReplyAndADryRunAreNotShownInTheWindow() async throws {
        let failed = try await run(windowSkill(), reply: "failed: 読めません")
        #expect(failed.kinds == ["forced", "started", "reply"])
        let dry = try await run(windowSkill(), dryRun: true, reply: "# 題")
        #expect(dry.kinds == ["forced", "started", "reply"])
    }

    @Test func otherSkillsAreUnchanged() async throws {
        let reporter = try await run(skill("plain", "x"), reply: "done: 開いた")
        #expect(reporter.kinds == ["forced", "started", "reply"])
    }
}

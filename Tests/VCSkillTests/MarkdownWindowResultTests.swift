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

/// 実行の途中でできた文書（`vc see` の答え）：返事（言語モデルの短い言い換え）ではなく、文書が、ウィンドウに出る。スキルの `result` に関わらない。失敗の返事・dry-run は、出さない。
@Suite struct ProducedDocumentTests {
    private final class SeeExecutor: SkillExecuting, @unchecked Sendable {
        let executedCommands = ["vc see"]
        let reply: String
        init(reply: String) { self.reply = reply }
        var producedDocument: String? { "# 画像の文字\n\n請求書" }
        func run(request: String) async throws -> String { reply }
    }

    private func run(reply: String, dryRun: Bool = false) async throws -> Recorder {
        let reporter = Recorder()
        _ = try await SkillRunner(selection: .forced(skill("see", "x")), dryRun: dryRun, makeExecutor: { _, _, _, _ in SeeExecutor(reply: reply) }).run("x", reporter: reporter, confirm: { false })
        return reporter
    }

    @Test func theProducedDocumentIsShownNotTheModelsReply() async throws {
        let reporter = try await run(reply: "done: 文字を書き出しました。請求書です")
        #expect(reporter.kinds == ["forced", "started", "document", "reply"])
        guard case let .document(markdown) = reporter.events[2], case let .reply(reply, _, _) = reporter.events[3] else { Issue.record("順序が違う"); return }
        #expect(markdown == "# 画像の文字\n\n請求書")
        #expect(reply == "done: 結果をウィンドウに表示しました")
    }

    @Test func aFailedReplyAndADryRunDoNotShowIt() async throws {
        #expect(try await run(reply: "failed: だめでした").kinds == ["forced", "started", "reply"])
        #expect(try await run(reply: "done: x", dryRun: true).kinds == ["forced", "started", "reply"])
    }
}

import Foundation
import Testing
@testable import VCSkill

/// `result: markdown-note`：スキルの返事を、Markdown のファイルにして開く（言語モデルは、本文だけを返す）。
@Suite struct ResultNoteTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theNoteIsWrittenPrivatelyUnderTheBaseDirectory() throws {
        let base = try temp()
        let file = try ResultNote.write("# 返信案\n\nはい、14時で大丈夫です。", in: base)
        #expect(file.path.hasPrefix(base.appendingPathComponent("voice-control-notes").path))
        #expect(file.pathExtension == "md")
        #expect(try String(contentsOf: file, encoding: .utf8) == "# 返信案\n\nはい、14時で大丈夫です。")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600 && dirMode == 0o700)
    }

    @Test func twoNotesInTheSameSecondDoNotOverwriteEachOther() throws {
        let base = try temp(), now = Date()
        let a = try ResultNote.write("a", in: base, now: now), b = try ResultNote.write("b", in: base, now: now)
        #expect(a != b)
        #expect(try String(contentsOf: a, encoding: .utf8) == "a")
    }

    @Test func aWholeReplyInACodeFenceIsUnwrapped() {
        #expect(ResultNote.unfenced("```markdown\n# T\n\ntext\n```") == "# T\n\ntext")
        #expect(ResultNote.unfenced("# T\n\n```swift\nlet x = 1\n```") == "# T\n\n```swift\nlet x = 1\n```")   // 途中のコードブロックは、そのまま
    }

    @Test func theResultFieldTurnsTheModeOnAndRejectsUnknownValues() throws {
        let on = try parse("---\nname: demo\ndescription: x\nallowed-commands: agent-desktop snapshot\nresult: markdown-note\n---\nbody").get()
        #expect(on.result == .markdownNote)
        #expect(try parse("---\nname: demo\ndescription: x\nallowed-commands: open\nresult: markdown-window\n---\nbody").get().result == .markdownWindow)
        #expect(try parse("---\nname: demo\ndescription: x\nallowed-commands: open\n---\nbody").get().result == .text)
        if case .failure(let e) = parse("---\nname: demo\ndescription: x\nallowed-commands: open\nresult: html\n---\nbody") { #expect(e.reason.contains("markdown-window")) } else { Issue.record("不明な result が、通った") }
    }

    /// 失敗の返事・dry-run は、ファイルにしない（`done: …` に置き換えるのは、保存して開けたときだけ）。
    @Test func aFailedReplyAndADryRunAreNotSavedAsNotes() {
        var skill = skill("demo", "x"); skill.result = .markdownNote
        let display = ExecutionDisplay(onCommand: { _ in }, onResult: { _, _ in }, onDenied: { _, _ in })
        let live = CommandSession(skill: skill, dryRun: false, display: display, cancel: nil)
        #expect(live.openAsNoteIfRequested("failed: 画面を読めません") == "failed: 画面を読めません")
        #expect(CommandSession(skill: skill, dryRun: true, display: display, cancel: nil).openAsNoteIfRequested("# メモ") == "# メモ")
    }
}

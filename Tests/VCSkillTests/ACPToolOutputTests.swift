import Foundation
import Testing
@testable import VCSkill

/// ツールの結果（コマンドの出力・差分）を、画面に出す形にする：agy・opencode が実際に返した形で。
@Suite struct ACPToolOutputTests {
    private func text(_ string: String) -> JSONValue { .object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string(string)])]) }
    private func diff(path: String? = "/work/a.txt", old: String?, new: String) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string("diff"), "newText": .string(new)]
        if let path { object["path"] = .string(path) }
        if let old { object["oldText"] = .string(old) }
        return .object(object)
    }

    @Test func aCommandsOutputDropsTheAgentsTimestampHeaderAndLineEndings() {
        // agy の実際の形：時刻の見出し・終了コード・「Command output:」・CRLF
        let agy = text("Created At: 2026-11-17T07:53:39+09:00\nCompleted At: 2026-11-17T07:53:40+09:00\nCommand exited with code 0.\n\nCommand output:\ntotal 8\r\n-rw-r--r--  1 u  wheel  20 a.txt\r\n")
        let output = ACPToolOutput.make(kind: "execute", content: [agy])
        #expect(output?.isDiff == false)
        #expect(output?.text == "Command exited with code 0.\n\nCommand output:\ntotal 8\n-rw-r--r--  1 u  wheel  20 a.txt")
        #expect(ACPToolOutput.make(kind: "execute", content: [text("   \n")]) == nil)            // 空は、出さない
        #expect(ACPToolOutput.make(kind: "execute", content: []) == nil)
    }

    @Test func anEditShowsItsDiffOnlyAndNotTheSuccessSentence() {
        // opencode の実際の形：「Success. …」の文と、diff
        let output = ACPToolOutput.make(kind: "edit", content: [text("Success. Updated the following files:\nM a.txt"), diff(old: "hello world\nfoo bar\n", new: "hello world\nbaz bar\n")])
        #expect(output?.isDiff == true)
        #expect(output?.text == "--- a.txt\n hello world\n-foo bar\n+baz bar")
        #expect(ACPToolOutput.make(kind: "edit", content: [text("Success.")]) == nil)             // 差分がなければ、出さない
        let created = ACPToolOutput.make(kind: "edit", content: [diff(path: nil, old: nil, new: "hello\n")])   // 新しいファイル：全部が追加（agy）
        #expect(created?.text == "+hello")
    }

    @Test func readsSearchesAndOthersShowNothingBecauseTheAnswerCarriesWhatMatters() {
        for kind in ["read", "search", "fetch", "think", "other", "switch_mode"] {
            #expect(ACPToolOutput.make(kind: kind, content: [text("ファイルの中身")]) == nil, "出さない：\(kind)")
        }
    }

    @Test func aDiffKeepsOnlyChangedLinesWithAFewLinesOfContextAndElidesTheRest() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 10\n", with: "ten\n")
        let lines = ACPDiff.unified(old: old, new: new).components(separatedBy: "\n")
        #expect(lines == ["…", " line 8", " line 9", "-line 10", "+ten", " line 11", " line 12", "…"])
        #expect(ACPDiff.unified(old: "a\n", new: "a\n") == "…")   // 変わらない：変わった行がないので、省略の印だけ
    }

    @Test func aLongOutputIsClippedWithAMarkAndAShortOneIsKept() {
        let many = (1...200).map { "row \($0)" }.joined(separator: "\n")
        let clipped = ChatActivity.Output(text: many)
        #expect(clipped.text.components(separatedBy: "\n").count == ChatActivity.Output.maxLines + 1 && clipped.text.hasSuffix("…（長いので、ここまで）"))
        #expect(ChatActivity.Output(text: "short\n").text == "short")
        let wide = ChatActivity.Output(text: String(repeating: "あ", count: 20_000))
        #expect(wide.text.count <= ChatActivity.Output.maxCharacters + 20 && wide.text.hasSuffix("…（長いので、ここまで）"))
    }

    @Test func claudesFencedOutputIsUsedAndTheCommandDescriptionIsNotMistakenForOutput() {
        // Claude の実際の形：説明（囲みなし）と、出力（```console の囲みつき）が、別の塊で来る
        let description = text("List files in current directory with details")
        let fenced = text("```console\ntotal 8\n-rw-r--r--  1 u  wheel  20 a.txt\n```")
        #expect(ACPToolOutput.make(kind: "execute", content: [description, fenced])?.text == "total 8\n-rw-r--r--  1 u  wheel  20 a.txt")
        #expect(ACPToolOutput.make(kind: "execute", content: [description])?.text == "List files in current directory with details")   // 囲みがなければ、すべて（agy・opencode）
    }

    @Test func codexsTerminalOutputFragmentsAreJoinedIntoTheOutput() {
        #expect(ACPToolOutput.terminal("total 8\r\n-rw-r--r--  a.txt\r\n")?.text == "total 8\n-rw-r--r--  a.txt")
        #expect(ACPToolOutput.terminal("  \n") == nil)
    }
}


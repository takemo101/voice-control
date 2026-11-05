import AppKit
import Foundation
import VCCore

struct ShowCommand: Command {
    static let info = CommandInfo(
        name: "show", group: .skills, summary: "Markdown を整形して、一時的なウィンドウに表示する（コピーもできる）",
        usage: ["vc show [--file <パス>] [--text <Markdown>] [--title <題名>] [--wait]", "<Markdown を出すコマンド> | vc show"],
        details: [
            "本文は、--text・--file・標準入力（パイプ）のどれか。ウィンドウは、見出し・太字・コード・リンク・箇条書き・表などを整形して見せる。文字は、選択して ⌘C でコピーできる。「Markdown をコピー」（元の記号つき）・「テキストをコピー」（整形した文字だけ）・「閉じる」（Esc）のボタンがある。",
            "既定では、ウィンドウを出して、すぐ戻る（`open` と同じ。ウィンドウは、別のプロセスで、閉じるまで残る）。--wait を付けると、閉じるまで、戻らない。",
            "スキルが、結果をウィンドウで見せるには、フロントマターに `result: markdown-window`（最後の返事が、Markdown の本文）。スキルの `allowed-commands` に `vc show` を書いて、モデルが呼ぶこともできる（長い本文を、コマンドの引数で渡すので、Apple のモデルでは、引用符が崩れやすい）。",
            "本文は、画面にだけ出す（ファイル・ログに残さない）。1 MB まで。",
        ],
        options: [("--file <パス>", "Markdown のファイル"), ("--text <Markdown>", "Markdown の文字"), ("--title <題名>", "ウィンドウの題名（既定：Markdown）"), ("--wait", "ウィンドウが閉じられるまで、戻らない")],
        examples: ["pbpaste | vc show", "vc show --file README.md", "vc show --text \"# 題\\n本文\" --wait"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let wait = arguments.flag("--wait")
        let title = arguments.option("--title") ?? "Markdown"
        let text = arguments.option("--text"), file = arguments.option("--file")
        let markdown: String
        if let text { markdown = text }
        else if let file {
            guard let data = FileManager.default.contents(atPath: (file as NSString).expandingTildeInPath), let content = String(data: data, encoding: .utf8) else { fail("ファイルを読めません: \(file)") }
            markdown = content
        } else if isatty(STDIN_FILENO) == 0 {
            markdown = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else {
            usageError("show", "本文を渡してください（--text・--file・標準入力）")
        }
        guard !markdown.isEmpty else { fail("本文が空です") }
        guard markdown.utf8.count <= DocumentWindow.maxBytes else { fail("本文が大きすぎます（\(DocumentWindow.maxBytes / 1000) KB まで）") }
        if wait {
            MarkdownWindow.runUntilClosed(markdown: markdown, title: title)
        }
        if let why = DocumentWindow.present(markdown: markdown, title: title) { fail(why) }
    }
}

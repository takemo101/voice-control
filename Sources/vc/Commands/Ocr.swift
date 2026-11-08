import Foundation
import VCCore
import VCSkill

struct OcrCommand: Command {
    static let info = CommandInfo(
        name: "ocr", group: .skills, summary: "範囲を選んで、画面の文字だけを書き出し、ウィンドウに出す（声は使わない）",
        usage: ["vc ocr", "vc ocr --file <画像>"],
        details: [
            "画面を暗くして、ドラッグで範囲を選ぶ（Esc で取りやめ）。範囲の文字を読み取って、vc show と同じウィンドウに出す（コピーできる）。",
            "読み取りは、macOS の文字認識（日本語・英語）。**この Mac の中だけ**で動き、言語モデルを通さない（速く、写し間違い・補足をしない）。画像は、読み取ったら消す。",
            "ショートカットで使うなら、vc hotkey set-ocr <キー>（vc listen --hotkey の中で動く）。",
            "画面収録の許可が要る（システム設定 > プライバシーとセキュリティ > 画面収録。vc を動かしているターミナルに）。",
            "--file：撮らずに、画像のファイルの文字を読む。",
        ],
        options: [("--file <画像>", "画像のファイル（撮らない）")],
        examples: ["vc ocr", "vc ocr --file page.png"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let text: String
        if let file = arguments.option("--file") {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { fail("ファイルがありません: \(file)") }
            do { text = try ScreenText.recognize(url) } catch { fail("\(error)") }
        } else {
            print(Style.dim("範囲をドラッグで選ぶ・ウィンドウをクリック・↩ で全画面（Esc で取りやめ）"))
            switch ScreenSelector.runStandalone({ await ScreenCapture.recognizeRegion() }) {
            case .success(nil): print(Style.dim("取りやめました")); return
            case let .success(read?): text = read
            case let .failure(failure): fail(failure.message)
            }
        }
        guard !text.isEmpty else { print(Style.yellow("文字が見つかりませんでした")); return }
        if let why = DocumentWindow.present(markdown: TranscriptDocument.markdown(text), title: "文字起こし") { fail(why) }
        print(Style.green("✓") + " 文字を書き出しました（\(text.count) 文字）。ウィンドウに出しました")
    }
}

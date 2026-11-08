import Foundation
import VCCore
import VCSkill

struct OcrCommand: Command {
    static let info = CommandInfo(
        name: "ocr", group: .skills, summary: "画像の文字を読み取って、標準出力へ出す（範囲を選んで撮るか、ファイルから）",
        usage: ["vc ocr", "vc ocr --file <画像>"],
        details: [
            "引数なし：画面を静止して、範囲を選ぶ（ドラッグ・ウィンドウをクリック・↩ で全画面。Esc で取りやめ）。範囲の文字を読み取って、**標準出力**へ出す（`vc ocr | pbcopy` で、コピー）。画像は、読み取ったら消す。",
            "読み取りは、macOS の文字認識（日本語・英語）。**この Mac の中だけ**で動き、言語モデルを通さない（速く、写し間違い・補足をしない）。最初の 1 回は、システムのモデルの準備で 30 秒ほどかかる。",
            "画面を見ながら使うなら、スクリーンショットのあとに出る**画像のパネルの「文字起こし」**が手軽（vc hotkey set-shot で撮るショートカットを決める）。",
            "画面収録の許可が要る（システム設定 > プライバシーとセキュリティ > 画面収録。vc を動かしているターミナルに）。",
            "--file：撮らずに、画像のファイルの文字を読む。",
        ],
        options: [("--file <画像>", "画像のファイル（撮らない）")],
        examples: ["vc ocr", "vc ocr --file page.png", "vc ocr | pbcopy"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let text: String
        if let file = arguments.option("--file") {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { fail("ファイルがありません: \(file)") }
            do { text = try ScreenText.recognize(url) } catch { fail("\(error)") }
        } else {
            eprint(Style.dim("範囲をドラッグで選ぶ・ウィンドウをクリック・↩ で全画面（Esc で取りやめ）"))
            switch ScreenSelector.runStandalone({ await ScreenCapture.recognizeRegion() }) {
            case .success(nil): eprint(Style.dim("取りやめました")); return
            case let .success(read?): text = read
            case let .failure(failure): fail(failure.message)
            }
        }
        guard !text.isEmpty else { eprint(Style.yellow("文字が見つかりませんでした")); return }
        print(text)
    }
}

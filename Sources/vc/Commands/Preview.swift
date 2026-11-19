import Foundation
import VCCore
import VCSkill

struct PreviewCommand: Command {
    static let info = CommandInfo(
        name: "preview", group: .skills, summary: tr("画像を、一時的なパネルに表示する（画像のコピー・文字起こし・パスのコピー・Finder で表示）"),
        usage: [tr("vc preview <画像> [--title <題名>] [--wait] [--render <出力の PNG>]"), tr("<PNG を出すコマンド> | vc preview")],
        details: [
            tr("画像（PNG・JPEG・HEIC）は、引数のファイルか、標準入力（PNG）。パネルは、vc show と同じ見た目で、見出しの右に、**画像をコピー**（⌘C）・文字起こし・「…」（**パスをコピー**・Finder で表示）・閉じる（Esc）が並ぶ。画像は、ドラッグして、ほかのアプリへ渡せる。"),
            tr("標準入力の画像（保存していないもの）は、「…」の「パスをコピー」「Finder で表示」を押したときに、初めて ~/Pictures/voice-control へ保存する。ファイルを渡したときは、そのパスを使う。"),
            tr("既定では、パネルを出して、すぐ戻る（パネルは、別のプロセスで、閉じるまで残る）。--wait を付けると、閉じるまで戻らない。"),
            tr("撮ったスクリーンショット（スクリーンショットのショートカット）と、image-edit スキルの結果は、自動で、このパネルに出る。"),
        ],
        options: [(tr("--title <題名>"), tr("パネルの題名（既定：画像）")), (tr("--saved-at <パス>"), tr("保存済みの画像のパス（内部用）")), (tr("--expires <UNIX 秒>"), tr("声で使えなくなる時刻（内部用。撮ったばかりの画像の、残り時間の表示）")), ("--wait", tr("閉じるまで戻らない")), (tr("--render <出力の PNG>"), tr("画面に出さず、パネルを、画像（PNG）に書き出す（見た目の確認用。画面は撮らない）"))],
        examples: ["vc preview ~/Pictures/voice-control/shot.png", "cat shot.png | vc preview --wait"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let wait = arguments.flag("--wait")
        let render = arguments.option("--render").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let title = arguments.option("--title") ?? tr("画像")
        let savedAt = arguments.option("--saved-at").map { URL(fileURLWithPath: $0) }
        let expiresAt = arguments.option("--expires").flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
        let png: Data
        var saved = savedAt
        if let path = arguments.positionals.first {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do { png = try ImageOps.pngData(contentsOf: url) } catch { fail(tr("画像を読めません: \(path)（\(error)）")) }
            saved = url
        } else if isatty(STDIN_FILENO) == 0 {
            png = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            usageError("preview", tr("画像を渡してください（ファイル・標準入力）"))
        }
        guard !png.isEmpty else { fail(tr("画像が空です")) }
        guard png.count <= 100_000_000 else { fail(tr("画像が大きすぎます（100 MB まで）")) }
        if let render { try ImageWindow.render(png: png, savedURL: saved, title: title, expiresAt: expiresAt, to: render); print(render.path); return }
        if wait { ImageWindow.runUntilClosed(png: png, savedURL: saved, title: title, expiresAt: expiresAt) }
        if let why = ImagePanel.present(png: png, title: title, savedAt: saved, expiresAt: expiresAt) { fail(why) }
    }
}

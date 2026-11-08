import Foundation
import VCCore
import VCSkill

struct PreviewCommand: Command {
    static let info = CommandInfo(
        name: "preview", group: .skills, summary: "画像を、一時的なパネルに表示する（画像・パスのコピー・Finder で表示）",
        usage: ["vc preview <画像> [--title <題名>] [--wait]", "<PNG を出すコマンド> | vc preview"],
        details: [
            "画像（PNG・JPEG・HEIC）は、引数のファイルか、標準入力（PNG）。パネルは、vc show と同じ見た目で、**画像をコピー**（⌘C）・**パスをコピー**・Finder で表示・画像のドラッグができる。",
            "標準入力の画像（保存していないもの）は、「パスをコピー」「Finder」を押したときに、初めて ~/Pictures/voice-control へ保存する。ファイルを渡したときは、そのパスを使う。",
            "既定では、パネルを出して、すぐ戻る（パネルは、別のプロセスで、閉じるまで残る）。--wait を付けると、閉じるまで戻らない。",
            "撮ったスクリーンショット（vc shot・ショートカット）と、image-edit スキルの結果は、自動で、このパネルに出る。",
        ],
        options: [("--title <題名>", "パネルの題名（既定：画像）"), ("--saved-at <パス>", "保存済みの画像のパス（内部用）"), ("--wait", "閉じるまで戻らない")],
        examples: ["vc preview ~/Pictures/voice-control/shot.png", "cat shot.png | vc preview --wait"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let wait = arguments.flag("--wait")
        let title = arguments.option("--title") ?? "画像"
        let savedAt = arguments.option("--saved-at").map { URL(fileURLWithPath: $0) }
        let png: Data
        var saved = savedAt
        if let path = arguments.positionals.first {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do { png = try ImageOps.pngData(contentsOf: url) } catch { fail("画像を読めません: \(path)（\(error)）") }
            saved = url
        } else if isatty(STDIN_FILENO) == 0 {
            png = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            usageError("preview", "画像を渡してください（ファイル・標準入力）")
        }
        guard !png.isEmpty else { fail("画像が空です") }
        guard png.count <= 100_000_000 else { fail("画像が大きすぎます（100 MB まで）") }
        if wait { ImageWindow.runUntilClosed(png: png, savedURL: saved, title: title) }
        if let why = ImagePanel.present(png: png, title: title, savedAt: saved) { fail(why) }
    }
}

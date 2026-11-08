import Foundation
import VCCore
import VCSkill

/// 画像を、パネルで見せる（呼び出し元は、待たない）。**別のプロセス**（`vc preview --wait`）を起こして、標準入力で PNG を渡す（`DocumentWindow` と同じ理由）。
/// 新しく出すとき、前のパネルは、閉じる（撮るたびに、積み上がらない）。
enum ImagePanel {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Process?

    /// 起こせなければ、理由を返す。`savedAt`：すでに保存してある画像のパス（「パスをコピー」が、そのパスを使う）。
    @discardableResult
    static func present(png: Data, title: String, savedAt: URL? = nil) -> String? {
        guard let executable = Bundle.main.executableURL else { return "vc の場所が分かりません" }
        lock.lock(); let previous = current; lock.unlock()
        previous?.terminate()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["preview", "--wait", "--title", title] + (savedAt.map { ["--saved-at", $0.path] } ?? [])
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "パネルを出せません（\(error.localizedDescription)）" }
        input.fileHandleForWriting.write(png)
        try? input.fileHandleForWriting.close()   // try?: 子が先に終わっていれば、閉じる失敗は、結果に関係しない
        lock.lock(); current = process; lock.unlock()
        return nil
    }

    /// ファイルの画像を見せる（`image-edit` の結果：保存済みなので、そのパスを使う）。
    @discardableResult
    static func present(file: URL, title: String) -> String? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return "画像を読めません" }
        // PNG 以外（JPEG・HEIC）は、PNG にして渡す（パネルは、PNG を受ける）
        let png: Data
        if file.pathExtension.lowercased() == "png" { png = data }
        else if let image = try? ImageOps.load(file), let converted = try? ImageOps.pngData(image) { png = converted }   // try?: 読めなければ、下で理由を返す
        else { return "画像を読めません" }
        return present(png: png, title: title, savedAt: file)
    }
}

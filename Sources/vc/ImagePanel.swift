import Foundation
import VCCore
import VCSkill

/// 画像を、パネルで見せる（呼び出し元は、待たない）。**別のプロセス**（`vc preview --wait`）を起こして、標準入力で PNG を渡す（`DetachedChild`）。
/// 新しく出すとき、前のパネルは、閉じる（撮るたびに、積み上がらない）。
enum ImagePanel {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Process?

    /// 起こせなければ、理由を返す。`savedAt`：すでに保存してある画像のパス（「パスをコピー」が、そのパスを使う）。
    @discardableResult
    static func present(png: Data, title: String, savedAt: URL? = nil) -> String? {
        lock.lock(); let previous = current; lock.unlock()
        previous?.terminate()
        switch DetachedChild.launch(arguments: ["preview", "--wait", "--title", title] + (savedAt.map { ["--saved-at", $0.path] } ?? []), input: png) {
        case let .success(process):
            lock.lock(); current = process; lock.unlock()
            return nil
        case let .failure(failure):
            return failure.reason
        }
    }

    /// ファイルの画像を見せる（`image-edit` の結果：保存済みなので、そのパスを使う）。
    @discardableResult
    static func present(file: URL, title: String) -> String? {
        do { return present(png: try ImageOps.pngData(contentsOf: file), title: title, savedAt: file) }
        catch { return "\(error)" }
    }
}

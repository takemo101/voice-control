import Foundation

/// Markdown の結果を、ウィンドウで見せる（呼び出し元は、待たない）。**別のプロセス**（`vc show --wait`）を起こして、標準入力で本文を渡す（`DetachedChild`）。
enum DocumentWindow {
    /// 本文の大きさの上限（外から来る文章なので、異常に大きいものは、出さない）。
    static let maxBytes = 1_000_000

    /// 起こせなければ、理由を返す（見せ方は、呼び出し側）。
    static func present(markdown: String, title: String? = nil) -> String? {
        guard markdown.utf8.count <= maxBytes else { return "本文が大きすぎます（\(maxBytes / 1000) KB まで）" }
        switch DetachedChild.launch(arguments: ["show", "--wait"] + (title.map { ["--title", $0] } ?? []), input: Data(markdown.utf8)) {
        case .success: return nil
        case let .failure(failure): return failure.reason
        }
    }
}

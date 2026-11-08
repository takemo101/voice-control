import Foundation

/// 結果の見せ先：Markdown の答え（`vc show` のウィンドウ）・加工した画像（画像のパネル）。どちらも、別のプロセスで開く。起こせなければ、理由を返す。
/// `HUDReporter`・`TerminalReporter` に、差し込む（テストで、差し替える）。
struct ResultPresenters: Sendable {
    var document: @Sendable (String) -> String?
    var image: @Sendable (URL) -> String?

    static let live = ResultPresenters(
        document: { DocumentWindow.present(markdown: $0) },
        image: { ImagePanel.present(file: $0, title: "加工した画像") })
}

import CoreGraphics

/// 会話の記録のスクロール位置：**最新（いちばん下）から離れているか**の判断（離れているとき、「最新へ」のボタンを出す）。純粋（画面を持たない）。
enum ChatScroll {
    /// 下の端から、これ以上離れたら、「離れている」。点（pt）。ふつうに読んでいて、少し上へずれただけでは、ボタンを出さない。
    static let threshold: CGFloat = 120

    /// - `contentHeight`：記録全体の高さ。`visibleMaxY`：いま見えている範囲の、下の端（記録の座標）。
    /// 記録が、ウィンドウより短い（スクロールの余地がない）ときは、離れていない。
    static func isAwayFromBottom(contentHeight: CGFloat, visibleMaxY: CGFloat, threshold: CGFloat = ChatScroll.threshold) -> Bool {
        contentHeight - visibleMaxY > threshold
    }

    /// 下へ戻るボタンの目印（`ScrollViewReader` の `scrollTo` の先）。
    static let bottomAnchor = "chat-bottom"
}

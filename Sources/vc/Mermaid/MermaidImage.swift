import AppKit
import BeautifulMermaid
import Foundation

/// Mermaid の図を、**画像**にする（`MarkdownRenderer` が、コードブロックの代わりに、文章の中へ置く）。
/// 描くのは、**BeautifulMermaid**（Swift で書かれた Mermaid の描画。MIT）と、その配置エンジン **elk-swift**（Eclipse Layout Kernel の Swift への移植。EPL-2.0）：フローチャート・状態遷移図・シーケンス図・クラス図・ER 図・XY チャート。
/// どちらも、WebView・JavaScript・ネットワークを使わない（この Mac の中で描く）。**円グラフだけ**は、対応していないので、自前（`PieDrawing`）。
/// 描けない（対応しない種類・解析できない書き方・大きすぎる）図は、`nil`：呼び出し側は、コードのまま見せる。
/// 注意：BeautifulMermaid の `renderImage` は、macOS で、**上下が逆**になる（上から下の座標を前提にした絵を、下から上の画像に、そのまま描く）。実際の画面でも、文字が逆さまに出た（実機の確認で、利用者が気づいた）。
/// **`prepare` で、描く部品を受け取り、自分で、上下を反転した（上から下の座標の）ビットマップに描いて**、`NSImage(cgImage:)` にする（`NSImage` の描画ハンドラ〔`flipped: true`〕は、文章の中の画像として描かれるとき、反転が、二重になった）。
@MainActor enum MermaidImage {
    /// 図の最大の幅（これを超えたら、縮める）。
    static let maxWidth: CGFloat = 560
    /// 縮めたあとの、高さの上限と、縮める割合の下限（縦に長すぎる図・縮めて読めなくなる図は、コードのまま）。
    static let maxHeight: CGFloat = 1400
    static let minScale: CGFloat = 0.4
    /// 受け付ける文字数の上限（異常に大きい図は、描かない）。
    static let maxSource = 6000

    /// 暗いガラスの上で読める色（背景は、塗らない）。
    static let theme = DiagramTheme(
        background: NSColor(white: 0.07, alpha: 1), foreground: NSColor(white: 0.95, alpha: 1),
        line: NSColor(white: 1, alpha: 0.6), accent: NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.82, alpha: 1), muted: NSColor(white: 1, alpha: 0.62),
        surface: NSColor(white: 1, alpha: 0.09), border: NSColor(white: 1, alpha: 0.45),
        font: NSFont.systemFont(ofSize: 13), lineWidth: 1.4, cornerRadius: 8, transparent: true)

    static func image(for source: String) -> NSImage? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxSource else { return nil }
        if text.lowercased().hasPrefix("pie") {
            guard let chart = PieChart.parse(text) else { return nil }
            let size = PieDrawing.size(chart)
            return make(size: size) { _ in PieDrawing.draw(chart, size: size) }
        }
        // try?: 描けない図（対応しない種類・解析できない書き方）は、コードのまま
        guard let prepared = try? MermaidImageRenderer(theme: theme).prepare(from: text), prepared.bounds.width > 1, prepared.bounds.height > 1 else { return nil }
        let bounds = prepared.bounds
        let scale = min(1, maxWidth / bounds.width, maxHeight / bounds.height)
        guard scale >= minScale else { return nil }
        // 細かく見えるよう、画素は 2 倍（網膜）。上下を反転して、描く
        let pixel = scale * 2
        let width = Int(ceil(bounds.width * pixel)), height = Int(ceil(bounds.height * pixel))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: pixel, y: pixel)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        prepared.render(context, bounds)
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale)))
    }

    /// 上から下の座標の画像を作る（幅・高さの上限に合わせて縮める。縮めすぎるなら、作らない）。
    private static func make(size: CGSize, draw: @escaping (CGContext) -> Void) -> NSImage? {
        let scale = min(1, maxWidth / size.width, maxHeight / size.height)
        guard scale >= minScale else { return nil }
        return NSImage(size: CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale)), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: scale, y: scale)
            MainActor.assumeIsolated { draw(context) }
            return true
        }
    }
}

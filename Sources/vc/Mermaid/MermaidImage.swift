import AppKit
import BeautifulMermaid
import Foundation

/// Mermaid の図を、**画像**にする（`MarkdownRenderer` が、コードブロックの代わりに、文章の中へ置く。クリックで、拡大の窓：`MermaidZoomWindow`）。
/// 描くのは、**BeautifulMermaid**（Swift で書かれた Mermaid の描画。MIT）と、その配置エンジン **elk-swift**（Eclipse Layout Kernel の Swift への移植。EPL-2.0）：フローチャート・状態遷移図・シーケンス図・クラス図・ER 図・XY チャート。
/// どちらも、WebView・JavaScript・ネットワークを使わない（この Mac の中で描く）。**円グラフだけ**は、対応していないので、自前（`PieDrawing`）。
/// 描けない（対応しない種類・解析できない書き方・縮めると読めない）図は、`nil`：呼び出し側は、コードのまま見せる。
/// 注意：BeautifulMermaid の `renderImage` は、macOS で、**上下が逆**になる（上から下の座標を前提にした絵を、下から上の画像に、そのまま描く）。実際の画面でも、文字が逆さまに出た（実機の確認で、利用者が気づいた）。
/// **`prepare` で、描く部品を受け取り、自分で、上下を反転したビットマップに描いて**、`NSImage(cgImage:)` にする（`NSImage` の描画ハンドラ〔`flipped: true`〕は、文章の中の画像として描かれるとき、反転が、二重になった）。
@MainActor enum MermaidImage {
    /// 図の最大の幅（これを超えたら、縮める）。
    static let maxWidth: CGFloat = 560
    /// 縮めたあとの、高さの上限と、縮める割合の下限（縦に長すぎる図・縮めて読めなくなる図は、コードのまま）。
    static let maxHeight: CGFloat = 1400
    static let minScale: CGFloat = 0.4
    /// 受け付ける文字数の上限（異常に大きい図は、描かない）。
    static let maxSource = 6000
    /// 拡大の窓の画像の、画素の上限（長いほうの辺）。
    static let maxZoomPixels: CGFloat = 8000

    /// 暗いガラスの上で、**はっきり見える色**：文字は白・線は明るい青みの白・ノードは、青みを足した面と、はっきりした縁・矢じりと強調は、ティール。背景は、塗らない。
    static let theme = DiagramTheme(
        // 背景は塗らない（透明）が、**線の上の文字・ラベルの面の色は、背景と文字の色の混ぜ合わせで決まる**：背景を、少し明るい青みの暗色にして、ラベルの文字が、灰色に沈まないようにする
        background: NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.34, alpha: 1), foreground: NSColor(white: 1, alpha: 1),
        line: NSColor(calibratedRed: 0.78, green: 0.88, blue: 1, alpha: 0.92),
        accent: NSColor(calibratedRed: 0.36, green: 0.88, blue: 0.86, alpha: 1),
        muted: NSColor(calibratedRed: 0.90, green: 0.94, blue: 1, alpha: 0.96),   // 線の上の文字（ラベル）
        surface: NSColor(calibratedRed: 0.32, green: 0.52, blue: 0.95, alpha: 0.26),
        border: NSColor(calibratedRed: 0.62, green: 0.78, blue: 1, alpha: 0.95),
        font: NSFont.systemFont(ofSize: 13, weight: .medium), lineWidth: 1.6, cornerRadius: 8, transparent: true)

    /// 文章の中に置く画像（幅・高さの上限に合わせて縮める）。
    static func image(for source: String) -> NSImage? { render(source, zoom: false) }

    /// 拡大の窓の画像（縮めない。細かく見えるよう、画素を増やす）。
    static func zoomImage(for source: String) -> NSImage? { render(source, zoom: true) }

    private static func render(_ source: String, zoom: Bool) -> NSImage? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxSource else { return nil }
        if text.lowercased().hasPrefix("pie") {
            guard let chart = PieChart.parse(text) else { return nil }
            let size = PieDrawing.size(chart)
            return bitmap(size: size, zoom: zoom) { context in
                let graphics = NSGraphicsContext(cgContext: context, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                PieDrawing.draw(chart, size: size)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        // try?: 描けない図（対応しない種類・解析できない書き方）は、コードのまま
        guard let prepared = try? MermaidImageRenderer(theme: theme).prepare(from: text), prepared.bounds.width > 1, prepared.bounds.height > 1 else { return nil }
        let bounds = prepared.bounds
        return bitmap(size: bounds.size, zoom: zoom) { context in
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            prepared.render(context, bounds)
        }
    }

    /// 上から下の座標のビットマップに描いて、画像にする。`draw` は、上から下の座標で、`size` の大きさに描く。
    private static func bitmap(size: CGSize, zoom: Bool, draw: (CGContext) -> Void) -> NSImage? {
        let scale = zoom ? 1 : min(1, maxWidth / size.width, maxHeight / size.height)
        guard scale >= minScale else { return nil }
        // 細かく見えるよう、画素は 2 倍（網膜）。拡大の窓は、3 倍（上限あり）
        let pixel = zoom ? min(3, maxZoomPixels / max(size.width, size.height)) : scale * 2
        let width = Int(ceil(size.width * pixel)), height = Int(ceil(size.height * pixel))
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: pixel, y: pixel)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(context)
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale)))
    }
}

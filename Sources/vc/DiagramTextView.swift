import AppKit
import Foundation
import VCCore

extension NSAttributedString.Key {
    /// 図（Mermaid）の画像の印：値は、元の Mermaid の文字。クリックで、拡大の窓を開く（`DiagramTextView`）。
    static let mermaidSource = NSAttributedString.Key("vc.mermaidSource")
    /// 文章の中の画像（Markdown の画像）の印：値は、拡大の窓で見せる画像（`NSImage`）。
    static let zoomImage = NSAttributedString.Key("vc.zoomImage")
}

/// 文章の中の図・画像の（1 文字の）添付：**置かれた場所の幅に合わせて、縮める**（広い窓では、大きいまま・狭い窓では、はみ出さず・切れずに、縮む）。縮めても、画像は、細かく描いてあるので、読める。
final class DiagramAttachment: NSTextAttachment {
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        guard let size = image?.size, size.width > 0 else { return super.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex) }
        let available = max(80, lineFrag.width - 2)   // 面の左右の余白は、行の幅に、含まれていない（端の 1〜2 点の誤差）
        let scale = min(1, available / size.width)
        return CGRect(x: 0, y: -2, width: size.width * scale, height: size.height * scale)
    }
}

/// 文章の中の図を、**クリックすると、拡大の窓が開く**テキストビュー（`MarkdownWindow`・会話のウィンドウが使う）。それ以外のクリックは、ふつうの `NSTextView`（選択・リンク）。
/// 図の上は、指のカーソルにする。
final class DiagramTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let source = diagramSource(at: point) {
            MainActor.assumeIsolated { ImageZoomWindow.show(source: source) }
            return
        }
        if let image = zoomImage(at: point) {
            MainActor.assumeIsolated { ImageZoomWindow.show(image: image, title: tr("画像")) }
            return
        }
        super.mouseDown(with: event)
    }

    /// リンクのクリック：**この Mac の中のファイル**は、文書・画像なら開き、それ以外（フォルダ・実行ファイル・知らない種類）は、Finder で示す（`MarkdownLink`）。ほかのリンク（http など）は、標準のまま。
    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL, url.isFileURL { MainActor.assumeIsolated { MarkdownLink.openFile(url) }; return }
        super.clicked(onLink: link, at: charIndex)
    }

    /// その位置にある図の、元の文字（図の絵の中のときだけ）。
    func diagramSource(at point: NSPoint) -> String? {
        guard let source = attributeValue(.mermaidSource, at: point) as? String, !source.isEmpty else { return nil }
        return source
    }

    /// その位置にある、文章の中の画像（拡大の窓で見せるもの）。
    func zoomImage(at point: NSPoint) -> NSImage? { attributeValue(.zoomImage, at: point) as? NSImage }

    /// 図・画像の上のクリックのときだけ、その印の値（絵の矩形の中だけ）。
    private func attributeValue(_ key: NSAttributedString.Key, at point: NSPoint) -> Any? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length, let value = storage.attribute(key, at: index, effectiveRange: nil) else { return nil }
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return rect.contains(local) ? value : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return }
        for key in [NSAttributedString.Key.mermaidSource, .zoomImage] {
            storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard value != nil else { return }
                let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                addCursorRect(rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).intersection(bounds), cursor: .pointingHand)
            }
        }
    }
}

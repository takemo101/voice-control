import AppKit
import Foundation

extension NSAttributedString.Key {
    /// 図（Mermaid）の画像の印：値は、元の Mermaid の文字。クリックで、拡大の窓を開く（`DiagramTextView`）。
    static let mermaidSource = NSAttributedString.Key("vc.mermaidSource")
}

/// 文章の中の図の画像：**置かれた場所の幅に合わせて、縮める**（広い窓では、大きいまま・狭い窓では、はみ出さず・切れずに、縮む）。縮めても、画像は、細かく描いてあるので、読める。
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
            MainActor.assumeIsolated { MermaidZoomWindow.show(source: source) }
            return
        }
        if let image = zoomImage(at: point) {
            MainActor.assumeIsolated { MermaidZoomWindow.show(image: image, title: "画像") }
            return
        }
        super.mouseDown(with: event)
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

/// 拡大の窓：図を、**縮めずに**出す。**ピンチ（トラックパッド）・ダブルクリック・2 本指のダブルタップ**で、拡大縮小・**2 本指のスワイプ（スクロール）**で、動かす。Esc・⌘W で閉じる。
@MainActor final class MermaidZoomWindow: NSObject, NSWindowDelegate {
    private static var open: [MermaidZoomWindow] = []
    private let window: ZoomWindow
    private let scroll = NSScrollView()
    private let imageView = ZoomImageView()
    private let fitScale: CGFloat

    /// 図を、拡大の窓で見せる（描けなければ、何もしない）。
    static func show(source: String) {
        guard let image = MermaidImage.zoomImage(for: source) else { return }
        show(image: image, title: "図")
    }

    /// 画像を、拡大の窓で見せる。
    static func show(image: NSImage, title: String) {
        let controller = MermaidZoomWindow(image: image, title: title)
        open.append(controller)
        controller.present()
    }

    private init(image: NSImage, title: String) {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let limit = CGSize(width: screen.width * 0.85, height: screen.height * 0.85)
        let size = image.size
        fitScale = min(1, limit.width / max(1, size.width + 40), limit.height / max(1, size.height + 40))
        let content = CGSize(width: max(420, size.width * fitScale + 40), height: max(300, size.height * fitScale + 40))
        window = ZoomWindow(contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "\(title)（ピンチ・ダブルクリックで拡大縮小・Esc で閉じる）"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        // 会話のウィンドウ・Markdown のウィンドウ（`.statusBar` の 1 つ上）より、さらに上
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        window.minSize = NSSize(width: 320, height: 240)

        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: size)
        imageView.imageScaling = .scaleNone
        imageView.onDoubleClick = { [weak self] in self?.toggle() }
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = imageView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.magnification = fitScale
        window.contentView = scroll
    }

    private func present() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 全体が見える大きさ ⇄ 等倍（すでに等倍なら、2 倍）。
    private func toggle() {
        let target: CGFloat = abs(scroll.magnification - fitScale) < 0.02 ? (fitScale < 0.98 ? 1 : 2) : fitScale
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            scroll.animator().magnification = target
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

/// Esc で閉じられる窓。
private final class ZoomWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// ダブルクリックを受ける画像。
private final class ZoomImageView: NSImageView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}

/// 小さい図を、中央に置くクリップビュー（標準は、左上に寄る）。
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

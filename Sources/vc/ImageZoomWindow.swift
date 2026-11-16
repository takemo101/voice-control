import AppKit
import Foundation

/// 拡大の窓：図（Mermaid）・Markdown の画像を、**縮めずに**出す。**ピンチ（トラックパッド）・ダブルクリック・2 本指のダブルタップ**で、拡大縮小・**2 本指のスワイプ（スクロール）**で、動かす。Esc・⌘W で閉じる。
@MainActor final class ImageZoomWindow: NSObject, NSWindowDelegate {
    private static var open: [ImageZoomWindow] = []
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
        let controller = ImageZoomWindow(image: image, title: title)
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

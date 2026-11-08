import AppKit
import SwiftUI
import VCCore

/// 画像を見せる、一時的なパネル（`vc preview --wait`。`vc shot`・ショートカットで撮ったあとと、`image-edit` の結果が、これを別のプロセスで開く：`ImagePanel`）。
/// 見た目は、`vc show` のウィンドウと同じ **Liquid Glass のカード**。**画像をコピー**（⌘C）・**パスをコピー**・**Finder で表示**・画像をドラッグして、ほかのアプリへ渡す。
/// 撮ったばかりの画像は、まだファイルではない（`~/.voice-control/shot` は、3 分で消える一時の置き場所）：「パスをコピー」「Finder で表示」を押したときに、
/// 初めて `~/Pictures/voice-control` へ保存して、そのパスを使う（利用者が押したときだけ。押さなければ、何も残さない）。
@MainActor final class ImageWindow: NSObject, NSWindowDelegate {
    private let png: Data
    private let image: NSImage
    private let pixelSize: CGSize
    /// 保存済みのパス（`image-edit` の結果は、最初から。撮ったばかりの画像は、保存を押したあと）。
    private var savedURL: URL?
    private let window: ImagePanelFrame
    private let state = ImageState()

    private init(png: Data, image: NSImage, pixelSize: CGSize, savedURL: URL?, title: String) {
        self.png = png
        self.image = image
        self.pixelSize = pixelSize
        self.savedURL = savedURL
        let display = Self.displaySize(for: pixelSize)
        window = ImagePanelFrame(contentRect: NSRect(x: 0, y: 0, width: max(display.width + 36, 560), height: display.height + 150), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.copyImage = { [unowned self] in copyImage() }
        let root = ImageCardView(
            title: title, size: pixelSize, image: image, savedPath: savedURL?.path, state: state,
            copyImage: { [unowned self] in copyImage() },
            copyPath: { [unowned self] in copyPath() },
            reveal: { [unowned self] in reveal() },
            close: { [unowned self] in window.close() })
        window.contentView = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        // いま使っている画面の、右下
        let visible = ScreenPlacement.currentVisibleFrame()
        let size = window.frame.size
        window.setFrame(NSRect(x: visible.maxX - size.width - 24, y: visible.minY + 24, width: size.width, height: size.height), display: false)
    }

    /// 画像の表示の大きさ（ポイント）：最大 460 × 320 に収める（小さな画像は、そのまま）。
    static func displaySize(for pixels: CGSize) -> CGSize {
        let scale = min(1, 460 / max(pixels.width, 1), 320 / max(pixels.height, 1))
        return CGSize(width: max(220, (pixels.width * scale).rounded()), height: max(60, (pixels.height * scale).rounded()))
    }

    /// 表示して、閉じられるまで、イベントのループを回す（終わらない：閉じると、プロセスを終える）。
    static func runUntilClosed(png: Data, savedURL: URL?, title: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let image = NSImage(data: png), let rep = NSBitmapImageRep(data: png) else { fail("画像を読めません") }
        let controller = ImageWindow(png: png, image: image, pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh), savedURL: savedURL, title: title)
        controller.window.alphaValue = 0
        controller.window.orderFrontRegardless()   // 前面のアプリから、キーを奪わない
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            controller.window.animator().alphaValue = 1
        }
        withExtendedLifetime(controller) { app.run() }
        exit(0)
    }

    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }

    // MARK: 操作

    private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        flash(.image)
    }

    /// 保存して（まだなら）、パスを、文字としてコピーする。
    private func copyPath() {
        guard let url = persist() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        flash(.path)
    }

    private func reveal() {
        guard let url = persist() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 保存済みならそのパス。なければ、`~/Pictures/voice-control` へ保存する（初めて押されたとき）。
    private func persist() -> URL? {
        if let savedURL { return savedURL }
        do {
            let url = try ShotOutput.nextURL(ext: "png")
            try png.write(to: url, options: [.atomic])
            savedURL = url
            state.savedPath = url.path
            return url
        } catch {
            state.error = "保存できません（\(error.localizedDescription)）"
            return nil
        }
    }

    private func flash(_ button: ImageState.Button) {
        state.copied = button
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            if self?.state.copied == button { self?.state.copied = nil }
        }
    }
}

@MainActor final class ImageState: ObservableObject {
    enum Button { case image, path }
    @Published var copied: Button?
    @Published var savedPath: String?
    @Published var error: String?
}

/// 枠のないパネル：キーを受けられる（クリックしたあと）。⌘C は画像のコピー・⌘W・Esc で閉じる。前面のアプリを、アクティブにしない。
final class ImagePanelFrame: NSPanel {
    var copyImage: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "c": copyImage?(); return true
        case "w": close(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { close() } else { super.keyDown(with: event) } }
}

// MARK: - SwiftUI のカード

private struct ImageCardView: View {
    let title: String
    let size: CGSize
    let image: NSImage
    let savedPath: String?
    @ObservedObject var state: ImageState
    let copyImage: () -> Void
    let copyPath: () -> Void
    let reveal: () -> Void
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let display = ImageWindow.displaySize(for: size)
        VStack(spacing: 0) {
            header
            Rule()
            VStack(spacing: 8) {
                DraggableImage(image: image)
                    .frame(width: display.width, height: display.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                Text(caption).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
            }
            .padding(.vertical, 14).padding(.horizontal, 18)
            Rule()
            footer
        }
        .glassEffect(.regular.tint(DocumentPalette.accent.opacity(0.06)), in: shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.05), DocumentPalette.accent.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .clipShape(shape)
    }

    private var caption: String {
        if let error = state.error { return error }
        if let path = state.savedPath ?? savedPath { return (path as NSString).abbreviatingWithTildeInPath }
        return "まだ保存していません（「パスをコピー」で、~/Pictures/voice-control に保存）"
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(DocumentPalette.accent.opacity(0.2)).frame(width: 26, height: 26)
                Image(systemName: "photo.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(DocumentPalette.accent)
            }
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(verbatim: "\(Int(size.width)) × \(Int(size.height))").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(.white.opacity(0.1)))
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 19)).foregroundStyle(.white.opacity(0.45))
            }.buttonStyle(.plain).accessibilityLabel("閉じる")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(DragArea())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            PillButton(title: "画像をコピー", symbol: "photo.on.rectangle", flashed: state.copied == .image, action: copyImage)
            PillButton(title: "パスをコピー", symbol: "link", flashed: state.copied == .path, action: copyPath)
            PillButton(title: "Finder", symbol: "folder", flashed: false, action: reveal)
            Spacer(minLength: 4)
            PillButton(title: "閉じる", symbol: "xmark", flashed: false, cancel: true, action: close)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(DragArea())
    }
}

/// 画像（ドラッグして、ほかのアプリへ渡せる）。
private struct DraggableImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSView { DragImageView(image: image) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragImageView: NSView, NSDraggingSource {
        let image: NSImage
        init(image: NSImage) { self.image = image; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

        override func draw(_ dirtyRect: NSRect) {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }

        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: image)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

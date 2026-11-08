import AppKit
import SwiftUI
import VCCore
import VCSkill

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
        window = ImagePanelFrame(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        window.transcribe = { [unowned self] in toggleTranscript() }
        let root = ImageCardView(
            title: title, size: pixelSize, image: image, byteCount: png.count, savedPath: savedURL?.path, state: state,
            copyImage: { [unowned self] in copyImage() },
            copyPath: { [unowned self] in copyPath() },
            reveal: { [unowned self] in reveal() },
            transcribe: { [unowned self] in toggleTranscript() },
            copyText: { [unowned self] in copyTranscript() },
            close: { [unowned self] in window.close() })
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)   // 中身（画像の大きさ）に、合わせる
        // いま使っている画面の、右下
        let visible = ScreenPlacement.currentVisibleFrame()
        let size = window.frame.size
        window.setFrame(NSRect(x: visible.maxX - size.width - 24, y: visible.minY + 24, width: size.width, height: size.height), display: false)
    }

    /// 画像の表示の大きさ（ポイント）：最大 520 × 340 に収める（小さな画像は、そのまま）。
    static func displaySize(for pixels: CGSize) -> CGSize {
        let scale = min(1, 520 / max(pixels.width, 1), 340 / max(pixels.height, 1))
        return CGSize(width: max(200, (pixels.width * scale).rounded()), height: max(60, (pixels.height * scale).rounded()))
    }

    /// 表示して、閉じられるまで、イベントのループを回す（終わらない：閉じると、プロセスを終える）。
    static func runUntilClosed(png: Data, savedURL: URL?, title: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let image = NSImage(data: png), let rep = NSBitmapImageRep(data: png) else { fail("画像を読めません") }
        let controller = ImageWindow(png: png, image: image, pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh), savedURL: savedURL, title: title)
        controller.window.alphaValue = 0
        controller.window.orderFrontRegardless()   // 前面のアプリから、キーを奪わない
        ScreenText.warmUp()   // 最初の文字認識は、30 秒ほどかかる（システムのモデルの準備）。「文字起こし」を押すまでに、済ませておく
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

    // MARK: 文字起こし

    /// 文字の欄の高さ。
    private static let paneHeight: CGFloat = 237   // 欄の高さ 236 + 仕切り線
    private var paneOpen = false

    /// 「文字起こし」：画像の文字を読み取って（macOS の文字認識。**この Mac の中だけ**・言語モデルを通さない）、パネルの下に、そのまま（Markdown にせず）出す。もう一度押すと、閉じる。
    private func toggleTranscript() {
        if paneOpen { setPane(open: false); return }
        setPane(open: true)
        if case .text = state.transcript { return }   // 読み取り済み
        state.transcript = .reading
        let png = png
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ScreenText.recognize(data: png) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case let .success(text): self.state.transcript = text.isEmpty ? .empty : .text(text)
                    case let .failure(error): self.state.transcript = .failed("\(error)")
                    }
                }
            }
        }
    }

    private func copyTranscript() {
        guard case let .text(text) = state.transcript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(.text)
    }

    /// 文字の欄を、開く・閉じる（パネルの上端が伸び縮みする：下は、動かさない。画面の上へはみ出すなら、下げる）。
    private func setPane(open: Bool) {
        guard open != paneOpen else { return }
        paneOpen = open
        state.paneOpen = open
        var frame = window.frame
        let delta = open ? Self.paneHeight : -Self.paneHeight
        frame.size.height += delta
        let visible = ScreenPlacement.currentVisibleFrame()
        if frame.maxY > visible.maxY { frame.origin.y = max(visible.minY, visible.maxY - frame.height) }
        window.setFrame(frame, display: true, animate: true)
    }

    private func flash(_ button: ImageState.Button) {
        state.copied = button
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            if self?.state.copied == button { self?.state.copied = nil }
        }
    }
}

@MainActor final class ImageState: ObservableObject {
    enum Button { case image, path, text }
    enum Transcript: Equatable {
        case idle, reading, empty
        case text(String)
        case failed(String)
    }
    @Published var copied: Button?
    @Published var transcript: Transcript = .idle
    @Published var paneOpen = false
    @Published var savedPath: String?
    @Published var error: String?
}

/// 枠のないパネル：キーを受けられる（クリックしたあと）。⌘C は画像のコピー（文字を選んでいるときは、その文字）・⌘T は文字起こし・⌘W・Esc で閉じる。前面のアプリを、アクティブにしない。
final class ImagePanelFrame: NSPanel {
    var copyImage: (() -> Void)?
    var transcribe: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "c":
            // 文字起こしの欄で、文字を選んでいるときは、その文字（標準の動き）
            if let text = firstResponder as? NSTextView, text.selectedRange().length > 0 { return super.performKeyEquivalent(with: event) }
            copyImage?(); return true
        case "t": transcribe?(); return true
        case "w": close(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { close() } else { super.keyDown(with: event) } }
}

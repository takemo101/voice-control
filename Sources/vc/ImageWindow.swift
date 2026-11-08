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

// MARK: - SwiftUI のカード

private enum Tone {
    static let green = Color(red: 0.42, green: 0.90, blue: 0.62)
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.36)
}

private struct ImageCardView: View {
    let title: String
    let size: CGSize
    let image: NSImage
    let byteCount: Int
    let savedPath: String?
    @ObservedObject var state: ImageState
    let copyImage: () -> Void
    let copyPath: () -> Void
    let reveal: () -> Void
    let transcribe: () -> Void
    let copyText: () -> Void
    let close: () -> Void
    @StateObject private var stageHover = HoverState()

    private var display: CGSize { ImageWindow.displaySize(for: size) }
    private var cardWidth: CGFloat { max(display.width + 48, 520) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 0) {
            header
            Rule()
            VStack(spacing: 12) {
                stage
                metaRow
            }
            .padding(.top, 16).padding(.bottom, 14).padding(.horizontal, 24)
            if state.paneOpen {
                Rule()
                transcriptPane
            }
            Rule()
            footer
        }
        .frame(width: cardWidth)
        .glassEffect(.regular.tint(DocumentPalette.accent.opacity(0.06)), in: shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.05), DocumentPalette.accent.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .clipShape(shape)
    }

    // MARK: 見出し：題名・大きさ・右に、パスのコピー／Finder／閉じる

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(DocumentPalette.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "photo.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(DocumentPalette.accent)
            }
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(verbatim: "\(Int(size.width)) × \(Int(size.height))").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(.white.opacity(0.1)))
            Spacer(minLength: 8)
            IconButton(symbol: "link", label: "パスをコピー（まだなら、~/Pictures/voice-control に保存）", flashed: state.copied == .path, action: copyPath)
            IconButton(symbol: "folder", label: "Finder で表示（まだなら、~/Pictures/voice-control に保存）", flashed: false, action: reveal)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 21)).foregroundStyle(.white.opacity(0.45))
            }.buttonStyle(.plain).help("閉じる（Esc）").accessibilityLabel("閉じる")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(DragArea())
    }

    // MARK: 画像（透明な所は、市松模様。ドラッグして、ほかのアプリへ）

    private var stage: some View {
        ZStack(alignment: .bottomLeading) {
            Checkerboard()
            DraggableImage(image: image)
            if stageHover.on {
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw").font(.system(size: 11, weight: .semibold))
                    Text("ドラッグして、ほかのアプリへ").font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.62)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.7))
                .padding(10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: display.width, height: display.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.38), radius: 14, y: 6)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { stageHover.on = hovering } }
    }

    /// 形式・大きさ（バイト）と、保存の状態（保存していない／保存済みのパス）。
    private var metaRow: some View {
        HStack(spacing: 8) {
            Chip(text: "PNG · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))", dot: nil)
            if let error = state.error {
                Chip(text: error, dot: .red)
            } else if let path = state.savedPath ?? savedPath {
                Chip(text: (path as NSString).abbreviatingWithTildeInPath, dot: Tone.green, truncates: true)
            } else {
                Chip(text: "未保存（右上の リンク／フォルダ で保存）", dot: Tone.amber, truncates: true)
            }
            Spacer(minLength: 0)
        }
        .frame(width: display.width)
    }

    // MARK: 文字起こしの欄：読み取った文字を、そのまま

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder").font(.system(size: 12, weight: .semibold)).foregroundStyle(DocumentPalette.accent)
                Text("文字起こし").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if case let .text(text) = state.transcript {
                    Text(verbatim: "\(text.count) 文字").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(.white.opacity(0.1)))
                }
                Spacer(minLength: 8)
                if case .text = state.transcript {
                    PillButton(title: "テキストをコピー", symbol: "doc.on.doc", flashed: state.copied == .text, action: copyText)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.26))
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.8)
                switch state.transcript {
                case .idle, .reading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("読み取っています…（最初の 1 回は、準備で、30 秒ほどかかります）").font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                    }
                case .empty:
                    Text("文字が見つかりませんでした").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.62))
                case let .failed(message):
                    Text(message).font(.system(size: 12.5)).foregroundStyle(.red.opacity(0.9)).padding(12)
                case let .text(text):
                    TranscriptText(text: text).padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(height: 236)
    }

    // MARK: 下の行：よく使う 2 つ（画像のコピー・文字起こし）と、閉じる

    private var footer: some View {
        HStack(spacing: 10) {
            PrimaryPill(title: "画像をコピー", symbol: "photo.on.rectangle", key: "⌘C", flashed: state.copied == .image, action: copyImage)
            PillButton(title: state.paneOpen ? "文字を隠す" : "文字起こし", symbol: "text.viewfinder", flashed: false, action: transcribe)
            Spacer(minLength: 8)
            PillButton(title: "閉じる  esc", symbol: "xmark", flashed: false, cancel: true, action: close)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(DragArea())
    }
}

/// 主な操作のボタン（水色の面。キーの印つき）。
private struct PrimaryPill: View {
    let title: String
    let symbol: String
    let key: String
    let flashed: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: flashed ? "checkmark" : symbol).font(.system(size: 12, weight: .semibold))
                Text(flashed ? "コピーしました" : title).font(.system(size: 13, weight: .semibold))
                if !flashed { Text(key).font(.system(size: 10.5, weight: .bold, design: .rounded)).opacity(0.62) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15).padding(.vertical, 8)
            .background(Capsule().fill(DocumentPalette.accent.opacity(hover.on ? 0.42 : 0.30)))
            .overlay(Capsule().strokeBorder(DocumentPalette.accent.opacity(hover.on ? 0.75 : 0.5), lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// 丸いアイコンのボタン（押したあと、少しの間、チェック）。
private struct IconButton: View {
    let symbol: String
    let label: String
    let flashed: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: flashed ? "checkmark" : symbol).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(flashed ? DocumentPalette.accent : .white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(hover.on ? 0.22 : 0.12)))
                .overlay(Circle().strokeBorder(.white.opacity(hover.on ? 0.28 : 0.16), lineWidth: 0.7))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .onHover { hover.on = $0 }
        .accessibilityLabel(label)
    }
}

/// 小さな札（点つきで、状態を示せる）。
private struct Chip: View {
    let text: String
    let dot: Color?
    var truncates = false

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(verbatim: text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.08)))
        .layoutPriority(truncates ? 0 : 1)
    }
}

/// 透明な画像の下に敷く、市松模様。
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.07)))
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? cell : 0
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(.white.opacity(0.07)))
                    x += cell * 2
                }
                y += cell; row += 1
            }
        }
    }
}

/// 文字起こしの文字（`NSTextView`：選んで ⌘C・日本語の組みは、標準のまま）。
private struct TranscriptText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 12, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.selectedTextAttributes = [.backgroundColor: NSColor.systemTeal.withAlphaComponent(0.35)]
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: NSColor.white.withAlphaComponent(0.94), .paragraphStyle: paragraph]))
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

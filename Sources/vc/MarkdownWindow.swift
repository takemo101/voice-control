import AppKit
import SwiftUI

/// Markdown を整形して見せる、一時的なウィンドウ（`vc show --wait`。`vc show` と `result: markdown-window` は、これを別のプロセスで開く：`DocumentWindow`）。
/// 見た目は、**Liquid Glass のカード**（`glassEffect`：暗いガラス・角丸・細い光の縁）。枠のない、角丸のウィンドウで、背景をつかんで動かせ、縁で大きさを変えられる。
/// 枠（見出しの行・下のボタン）は SwiftUI、本文は `NSTextView`（`MarkdownRenderer`）：文字の選択・⌘C・日本語の組みは、標準のまま。
/// 文字は、選択して ⌘C でコピーできる。「Markdown をコピー」（元の記号つき）・「テキストをコピー」（整形した文字だけ）・「閉じる」（Esc）。閉じたら、プロセスを終える。
/// メインスレッドで動かす（`NSApplication` のループを回す。終わらない）。
@MainActor final class MarkdownWindow: NSObject, NSWindowDelegate {
    private let markdown: String
    private let titleText: String
    private let window: DocumentWindowFrame
    private let textView = NSTextView()
    private let state = DocumentState()

    private init(markdown: String, title: String) {
        self.markdown = markdown
        self.titleText = title
        window = DocumentWindowFrame(contentRect: NSRect(x: 0, y: 0, width: 660, height: 600), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)   // 背景の明るさに関わらず、同じ見た目（ガラスも、暗いほう）
        // 画面の上のパネル（`HUD`。`.statusBar`）より上に出す（裏に隠れない）
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 380, height: 280)
        window.collectionBehavior = [.fullScreenAuxiliary]
        configureTextView()
        let root = DocumentView(
            title: title, state: state, textView: textView,
            copyMarkdown: { [unowned self] in copy(self.markdown, button: .markdown) },
            copyText: { [unowned self] in copy(MarkdownRenderer.plainText(self.markdown), button: .text) },
            close: { [unowned self] in window.close() })
        window.contentView = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        window.textView = textView
        // いま使っている画面（マウスのある画面）の、真ん中
        window.setFrame(ScreenPlacement.centeredFrame(size: window.frame.size, in: ScreenPlacement.currentVisibleFrame()), display: false)
    }

    /// 表示して、ウィンドウが閉じられるまで、イベントのループを回す（終わらない：閉じると、プロセスを終える）。
    static func runUntilClosed(markdown: String, title: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // Dock に出さない
        let controller = MarkdownWindow(markdown: markdown, title: title)
        controller.window.alphaValue = 0
        controller.window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            controller.window.animator().alphaValue = 1
        }
        withExtendedLifetime(controller) { app.run() }
        exit(0)
    }

    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 20)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.selectedTextAttributes = [.backgroundColor: NSColor.systemTeal.withAlphaComponent(0.35)]
        textView.linkTextAttributes = [.foregroundColor: NSColor.systemTeal, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.textStorage?.setAttributedString(MarkdownRenderer.render(markdown))
    }

    /// クリップボードへ入れて、ボタンの文字を、少しの間、「コピーしました」にする。
    private func copy(_ text: String, button: DocumentState.Button) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.copied = button
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            if self?.state.copied == button { self?.state.copied = nil }
        }
    }
}

/// 画面の状態（どのボタンが「コピーしました」か）。SwiftUI の `@State` は、この環境（コマンドラインツールだけ）では、マクロのプラグインがなく使えないので、参照型にする。
@MainActor final class DocumentState: ObservableObject {
    enum Button { case markdown, text }
    @Published var copied: Button?
}

/// 触れると明るくなるボタンの、触れているかの状態。
@MainActor private final class HoverState: ObservableObject { @Published var on = false }

private enum Palette {
    static let accent = Color(red: 0.40, green: 0.82, blue: 1.0)
}

// MARK: SwiftUI の枠

private struct DocumentView: View {
    let title: String
    @ObservedObject var state: DocumentState
    let textView: NSTextView
    let copyMarkdown: () -> Void
    let copyText: () -> Void
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 0) {
            header
            Rule()
            // 本文：上下の端は、すっと消える（スクロールの途中で、文字が、線で切れない）
            TextBody(textView: textView)
                .mask(VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
                })
            Rule()
            footer
        }
        .glassEffect(.regular.tint(Palette.accent.opacity(0.06)), in: shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.05), Palette.accent.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .clipShape(shape)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Palette.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "doc.text.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
            }
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text("⌘C でコピー").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(.white.opacity(0.1)))
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.45))
            }.buttonStyle(.plain).accessibilityLabel("閉じる")
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(DragArea())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            PillButton(title: "Markdown をコピー", symbol: "doc.on.doc", flashed: state.copied == .markdown, action: copyMarkdown)
            PillButton(title: "テキストをコピー", symbol: "text.alignleft", flashed: state.copied == .text, action: copyText)
            Spacer(minLength: 8)
            PillButton(title: "閉じる  esc", symbol: "xmark", flashed: false, cancel: true, action: close)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(DragArea())
    }
}

/// つかんで、ウィンドウを動かせる面（見出しの行・下の行の、ボタンの外）。SwiftUI の面は、ウィンドウの背景のドラッグを受けないので、明示する。
private struct DragArea: View {
    var body: some View { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
}

/// 端で薄れる、細い仕切り線。
private struct Rule: View {
    var body: some View {
        Rectangle().fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.18), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)).frame(height: 0.7)
    }
}

/// 丸いボタン（薄い白の面。触れると、少し明るくなる。押したあと、少しの間、「コピーしました」）。
private struct PillButton: View {
    let title: String
    let symbol: String
    let flashed: Bool
    var cancel = false
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: flashed ? "checkmark" : symbol).font(.system(size: 12, weight: .semibold))
                Text(flashed ? "コピーしました" : title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(flashed ? Palette.accent : .white.opacity(0.92))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(hover.on ? 0.22 : 0.12)))
            .overlay(Capsule().strokeBorder(.white.opacity(hover.on ? 0.28 : 0.16), lineWidth: 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        // Esc：キー操作（`.cancelAction`）。最初の応答者が、どこでも、効く
        if cancel { button.keyboardShortcut(.cancelAction) } else { button }
    }
}

/// 本文（`NSTextView` を、スクロールの中に入れる）。
private struct TextBody: NSViewRepresentable {
    let textView: NSTextView

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// 枠のないウィンドウ：キーを受けられる。⌘C（選択をコピー）・⌘A（すべて選択）・⌘W（閉じる）を受ける（メニューバーのないアプリは、これらが、効かない）。Esc でも閉じる。
private final class DocumentWindowFrame: NSWindow {
    weak var textView: NSTextView?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "c": textView?.copy(nil); return true
        case "a": textView?.selectAll(nil); return true
        case "w": close(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    /// Esc：最初の応答者が、SwiftUI の面（ボタンを押したあと）でも、閉じる（`cancelOperation` が、窓まで届かないことがある）。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

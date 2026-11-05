import AppKit

/// Markdown を整形して見せる、一時的なウィンドウ（`vc show --wait`。`vc show` と `result: markdown-window` は、これを別のプロセスで開く：`DocumentWindow`）。
/// 見た目は、画面の上のパネル（`HUD`）と同じ（`HUDStyle`：暗いガラス・角丸・細い縁・同じ色と文字）。枠のない、角丸のウィンドウで、背景をつかんで動かせ、縁で大きさを変えられる。
/// 文字は、選択して ⌘C でコピーできる。「Markdown をコピー」（元の記号つき）・「テキストをコピー」（整形した文字だけ）・「閉じる」（Esc）。閉じたら、プロセスを終える。
/// メインスレッドで動かす（`NSApplication` のループを回す。終わらない）。
@MainActor final class MarkdownWindow: NSObject, NSWindowDelegate {
    private let markdown: String
    private let titleText: String
    private let window: DocumentWindowFrame
    private let textView = NSTextView()
    private var copyButtons: [PillButton] = []
    private var actions: [ButtonTarget] = []

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
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 380, height: 280)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.contentView = build()
        window.textView = textView
        window.center()
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

    // MARK: 組み立て

    private func build() -> NSView {
        let glass = HUDStyle.glassBackground()

        // 本文
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 26, height: 18)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.selectedTextAttributes = [.backgroundColor: NSColor.systemTeal.withAlphaComponent(0.35)]
        textView.linkTextAttributes = [.foregroundColor: NSColor.systemTeal, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.textStorage?.setAttributedString(MarkdownRenderer.render(markdown))

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let content = NSStackView(views: [header(), divider(), scroll, divider(), footer()])
        content.orientation = .vertical
        content.spacing = 0
        content.alignment = .leading
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in content.arrangedSubviews { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        glass.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
        ])
        return glass
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    /// 上の行：アイコン・題名・ヒント・閉じる（画面の上のパネルの見出しと同じ並び）。
    private func header() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold)) ?? NSImage())
        icon.contentTintColor = .systemTeal
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "閉じる")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) ?? NSImage(), target: nil, action: nil)
        let closeTarget = ButtonTarget { [unowned self] in window.close() }
        actions.append(closeTarget)
        close.target = closeTarget
        close.action = #selector(ButtonTarget.fire)
        close.isBordered = false
        close.contentTintColor = HUDStyle.secondary

        let row = NSStackView(views: [icon, title, spacer, HUDStyle.pill("⌘C でコピー", fg: HUDStyle.secondary, bg: HUDStyle.hairline(0.12)), close])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 13, right: 14)
        return row
    }

    /// 下の行：コピー（2 つ）・閉じる。
    private func footer() -> NSView {
        let copyMarkdown = pill("Markdown をコピー", symbol: "doc.on.doc") { [unowned self] in copy(markdown, from: 0) }
        let copyText = pill("テキストをコピー", symbol: "text.alignleft") { [unowned self] in copy(MarkdownRenderer.plainText(markdown), from: 1) }
        let close = pill("閉じる  esc", symbol: nil) { [unowned self] in window.close() }
        close.keyEquivalent = "\u{1b}"   // Esc
        copyButtons = [copyMarkdown, copyText]

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [copyMarkdown, copyText, spacer, close])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 11, left: 16, bottom: 13, right: 16)
        return row
    }

    private func pill(_ title: String, symbol: String?, _ run: @escaping () -> Void) -> PillButton {
        let target = ButtonTarget(run)
        actions.append(target)
        let button = PillButton(title: title, symbol: symbol)
        button.target = target
        button.action = #selector(ButtonTarget.fire)
        return button
    }

    /// クリップボードへ入れて、ボタンの文字を、少しの間、「コピーしました」にする。
    private func copy(_ text: String, from index: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButtons[index].flash("コピーしました")
    }
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
}

/// 丸いボタン（薄い白の面。触れると、少し明るくなる）。`HUDStyle.pill` と同じ色。
private final class PillButton: NSButton {
    private var tracking: NSTrackingArea?
    private let baseTitle: String

    init(title: String, symbol: String?) {
        baseTitle = title
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = HUDStyle.hairline(0.12).cgColor
        font = .systemFont(ofSize: 12, weight: .medium)
        contentTintColor = .white
        setButtonType(.momentaryChange)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            self.image = image
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        refreshTitle(baseTitle, color: .white)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 22, height: max(size.height, 22) + 4)
    }

    private func refreshTitle(_ text: String, color: NSColor) {
        attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color])
    }

    /// 少しの間、文字と色を替える（コピーしたとき）。
    func flash(_ text: String) {
        refreshTitle(text, color: .systemTeal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self else { return }
            refreshTitle(baseTitle, color: .white)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = HUDStyle.hairline(0.22).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = HUDStyle.hairline(0.12).cgColor }
}

private final class ButtonTarget: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

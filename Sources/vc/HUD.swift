import AppKit

/// 画面の上の中央に出す、小さなパネル（録音中・認識中・実行の経過・結果）。
/// クリックを通し、フォーカスを奪わない（操作の対象のアプリが、前面のまま）。画面の収録・アクセシビリティの許可は、要らない。
/// どのスレッドから呼んでもよい（内部でメインスレッドへ回す）。呼び出し側のプロセスが、`NSApplication.run()` で動いていること。
final class HUD: @unchecked Sendable {
    typealias Mode = HUDContent.Phase

    static let shared = HUD()

    private static let width: CGFloat = 468
    private static let inset = NSEdgeInsets(top: 14, left: 18, bottom: 15, right: 18)
    private static var rowWidth: CGFloat { width - inset.left - inset.right }

    private var panel: NSPanel?
    private var background: NSVisualEffectView?
    private var stack: NSStackView?
    private var pendingHide: DispatchWorkItem?
    private var visible = false
    private var generation = 0

    /// 1 行だけの簡単な表示。
    func show(_ text: String, mode: Mode, hideAfter: TimeInterval? = nil) {
        show(HUDContent(phase: mode, title: text), hideAfter: hideAfter)
    }

    /// 出す（すでに出ていれば、中身を差し替える）。`hideAfter` 秒後に消す（なければ、`hide()` まで出したまま）。
    func show(_ content: HUDContent, hideAfter: TimeInterval? = nil) {
        DispatchQueue.main.async { [self] in render(content, hideAfter: hideAfter) }
    }

    func hide() {
        DispatchQueue.main.async { [self] in fadeOut() }
    }

    // MARK: 描画（メインスレッド）

    private func render(_ content: HUDContent, hideAfter: TimeInterval?) {
        ensurePanel()
        guard let panel, let stack else { return }
        pendingHide?.cancel()
        generation += 1

        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let accent = Self.accent(content.phase)

        stack.addArrangedSubview(fixed(header(content, accent: accent)))
        if let hint = content.hint { stack.addArrangedSubview(fixed(label(hint, size: 12, color: Self.secondary, lines: 3))) }
        if let heard = content.heard, !heard.isEmpty {
            stack.addArrangedSubview(fixed(label("“\(heard)”", size: 13, color: Self.secondary, lines: 2)))
        }
        if !content.steps.isEmpty || content.reply != nil {
            let divider = NSBox()
            divider.boxType = .separator
            stack.addArrangedSubview(fixed(divider))
        }
        for step in content.steps { stack.addArrangedSubview(fixed(stepRow(step))) }
        if let reply = content.reply, !reply.isEmpty {
            stack.addArrangedSubview(fixed(label(reply, size: 14, color: .white, lines: 5, weight: .medium)))
        }

        stack.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height)
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let final = NSRect(x: screen.midX - Self.width / 2, y: screen.maxY - height - 16, width: Self.width, height: height)

        if !visible {
            panel.setFrame(final.offsetBy(dx: 0, dy: 10), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            visible = true
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }

        if let hideAfter {
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, token == generation else { return }
                fadeOut()
            }
            pendingHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
        }
    }

    private func fadeOut() {
        pendingHide?.cancel()
        guard visible, let panel else { return }
        generation += 1
        let token = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, token == generation else { return }  // その間に、新しい表示が来ていれば、消さない
            panel.orderOut(nil)
            visible = false
        })
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .vibrantDark)  // 背景の明るさに関わらず、同じ見た目
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = Self.inset
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        panel.contentView = background
        self.panel = panel
        self.background = background
        self.stack = stack
    }

    // MARK: 部品

    private static let secondary = NSColor(white: 1, alpha: 0.62)

    private static func accent(_ phase: Mode) -> NSColor {
        switch phase {
        case .recording, .failure: return .systemRed
        case .working: return .systemBlue
        case .success: return .systemGreen
        case .confirm: return .systemYellow
        case .info: return NSColor(white: 1, alpha: 0.7)
        }
    }

    private func fixed(_ view: NSView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        return view
    }

    private func label(_ text: String, size: CGFloat, color: NSColor, lines: Int, weight: NSFont.Weight = .regular, mono: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = lines
        field.lineBreakMode = .byTruncatingTail
        field.preferredMaxLayoutWidth = Self.rowWidth
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func header(_ content: HUDContent, accent: NSColor) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9

        if content.phase == .working {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.widthAnchor.constraint(equalToConstant: 18).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 18).isActive = true
            row.addArrangedSubview(spinner)
        } else {
            let symbol: String
            switch content.phase {
            case .recording: symbol = "mic.fill"
            case .success: symbol = "checkmark.circle.fill"
            case .failure: symbol = "xmark.octagon.fill"
            case .confirm: symbol = "questionmark.circle.fill"
            default: symbol = "info.circle.fill"
            }
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold)) ?? NSImage())
            icon.contentTintColor = accent
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
            if content.phase == .recording {
                icon.wantsLayer = true
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.3
                pulse.duration = 0.75
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                icon.layer?.add(pulse, forKey: "pulse")
            }
            row.addArrangedSubview(icon)
        }

        let title = NSTextField(labelWithString: content.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(title)

        if let skill = content.skill { row.addArrangedSubview(pill(skill, fg: .systemTeal, bg: NSColor.systemTeal.withAlphaComponent(0.2))) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        if let chip = content.chip { row.addArrangedSubview(pill(chip, fg: Self.secondary, bg: NSColor(white: 1, alpha: 0.12))) }
        return row
    }

    private func pill(_ text: String, fg: NSColor, bg: NSColor) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = fg
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = bg.cgColor
        box.layer?.cornerRadius = 9
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            field.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
        box.setContentHuggingPriority(.required, for: .horizontal)
        return box
    }

    private func stepRow(_ step: HUDContent.Step) -> NSView {
        let glyph: String
        let color: NSColor
        switch step.status {
        case .running: glyph = "▸"; color = .systemBlue
        case .ok: glyph = "✓"; color = .systemGreen
        case .failed: glyph = "✗"; color = .systemRed
        case .denied: glyph = "⊘"; color = .systemOrange
        }
        let mark = NSTextField(labelWithString: glyph)
        mark.font = .systemFont(ofSize: 13, weight: .bold)
        mark.textColor = color
        mark.setContentHuggingPriority(.required, for: .horizontal)

        let command = NSTextField(labelWithString: step.command)
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.textColor = NSColor(white: 1, alpha: 0.92)
        command.lineBreakMode = .byTruncatingMiddle
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let line = NSStackView(views: [mark, command])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 7

        guard let output = step.output, !output.isEmpty else { return line }
        let result = NSTextField(labelWithString: output)
        result.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        result.textColor = Self.secondary
        result.lineBreakMode = .byTruncatingTail
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let indent = NSStackView(views: [NSView(), result])
        indent.orientation = .horizontal
        indent.spacing = 0
        indent.views[0].translatesAutoresizingMaskIntoConstraints = false
        indent.views[0].widthAnchor.constraint(equalToConstant: 17).isActive = true

        let column = NSStackView(views: [fixed(line, width: Self.rowWidth), fixed(indent, width: Self.rowWidth)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    private func fixed(_ view: NSView, width: CGFloat) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }
}

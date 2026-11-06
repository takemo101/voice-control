import AppKit

/// 画面の上の中央に出す、小さなパネル（録音中・認識中・実行の経過・結果）。
/// クリックを通し、フォーカスを奪わない（操作の対象のアプリが、前面のまま）。画面の収録・アクセシビリティの許可は、要らない。
/// どのスレッドから呼んでもよい（`show`・`hide` は `nonisolated`：内部でメインスレッドへ回す）。呼び出し側のプロセスが、`NSApplication.run()` で動いていること。
/// 描画の状態は、メインアクターの上でだけ触る（`@MainActor`）。メインキューのブロックは、`assumeIsolated` で入る。
@MainActor final class HUD {
    typealias Mode = HUDContent.Phase

    nonisolated init() {}
    nonisolated static let shared = HUD()

    private static let width: CGFloat = 468
    private static let inset = NSEdgeInsets(top: 14, left: 18, bottom: 15, right: 18)
    private static var rowWidth: CGFloat { width - inset.left - inset.right }
    /// 録音中・認識中の、小さなカプセル（波形・考え中のドットだけ。本文はない）。
    private static let compactWidth: CGFloat = 376
    private static let compactInset = NSEdgeInsets(top: 13, left: 18, bottom: 13, right: 18)
    private static var compactRowWidth: CGFloat { compactWidth - compactInset.left - compactInset.right }
    /// 本文の高さの上限。超えたら、スクロールする（最新の行が見える位置で、出す）。
    private static let maxBodyHeight: CGFloat = 300

    /// 「実行する」「やめる」のボタンの答えの届け先（確認を待っている処理が、つなぐ）。
    nonisolated let answers = AnswerRoute()

    private var panel: HUDPanel?
    private var buttonActions: [ButtonAction] = []
    /// 確認のボタン（実行する・やめる）。キーで選ぶときの、フォーカスの移動先。
    private var choiceButtons: [NSButton] = []
    private var background: NSVisualEffectView?
    private var stack: NSStackView?
    /// 見出しの下の本文（補足・聞こえた文・コマンド・返事・ボタン）。長いときは、ここだけが、スクロールする（見出しは、動かない）。
    private var body: NSStackView?
    private var scroll: NSScrollView?
    private var bodyHeight: NSLayoutConstraint?
    private var pendingHide: DispatchWorkItem?
    /// 出している間、マウスのある画面を見張る（別のディスプレイへ移ったら、パネルも、そこへ移る）。
    private var followTimer: Timer?
    private var panelHeight: CGFloat = 0
    private var panelWidth: CGFloat = 468
    private var widthConstraint: NSLayoutConstraint?
    private var glow: GlowBorderView?
    private weak var waveform: WaveformView?
    private var visible = false
    private var generation = 0
    /// 仮想デスクトップ（Space）を移ったとき、出している間は、パネルを、移動先で出し直す。
    private var spaceObserver: NSObjectProtocol?

    /// 1 行だけの簡単な表示。
    nonisolated func show(_ text: String, mode: Mode, hideAfter: TimeInterval? = nil) {
        show(HUDContent(phase: mode, title: text), hideAfter: hideAfter)
    }

    /// 出す（すでに出ていれば、中身を差し替える）。`hideAfter` 秒後に消す（なければ、`hide()` まで出したまま）。
    nonisolated func show(_ content: HUDContent, hideAfter: TimeInterval? = nil) {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { render(content, hideAfter: hideAfter) } }
    }

    /// 録音中の音量（0〜1）。波形に出す（録音中のカプセルが出ていなければ、何もしない）。どのスレッドから呼んでもよい。
    nonisolated func pushLevel(_ level: Float) {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { waveform?.push(level) } }
    }

    nonisolated func hide() {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { fadeOut() } }
    }

    // MARK: 描画（メインスレッド）

    private func render(_ content: HUDContent, hideAfter: TimeInterval?) {
        ensurePanel()
        guard let panel, let stack, let body, let scroll, let bodyHeight else { return }
        pendingHide?.cancel()
        generation += 1
        buttonActions = []
        choiceButtons = []

        // 見出しは、いつも、いちばん上（動かない）。そのほかは、本文（長ければ、スクロール）
        for view in stack.arrangedSubviews where view !== scroll { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
        let accent = Self.accent(content.phase)
        let isCompact = content.isCompact
        waveform = nil
        stack.edgeInsets = isCompact ? Self.compactInset : Self.inset
        widthConstraint?.constant = isCompact ? Self.compactWidth : Self.width
        let radius: CGFloat = isCompact ? 24 : HUDStyle.cornerRadius
        background?.layer?.cornerRadius = radius
        glow?.cornerRadius = radius
        glow?.show(colors: Self.glowColors(content))

        if isCompact {
            stack.insertArrangedSubview(fixed(compactView(content), width: Self.compactRowWidth), at: 0)
        } else {
            stack.insertArrangedSubview(fixed(header(content, accent: accent)), at: 0)
            if let hint = content.hint { body.addArrangedSubview(fixed(label(hint, size: 12, color: HUDStyle.secondary, lines: 3))) }
            if let heard = content.heard, !heard.isEmpty {
                body.addArrangedSubview(fixed(label("“\(heard)”", size: 13, color: HUDStyle.secondary, lines: 2)))
            }
            if !content.steps.isEmpty || content.reply != nil {
                let divider = NSBox()
                divider.boxType = .separator
                body.addArrangedSubview(fixed(divider))
            }
            for step in content.steps { body.addArrangedSubview(fixed(stepRow(step))) }
            if let reply = content.reply, !reply.isEmpty {
                body.addArrangedSubview(fixed(label(reply, size: 14, color: .white, lines: 5, weight: .medium)))
            }
            if content.choices { body.addArrangedSubview(fixed(choiceRow())) }
        }

        // 本文が、上限を超えたら、スクロールにして、最新の行（下）を見せる
        scroll.isHidden = body.arrangedSubviews.isEmpty
        // 幅が決まってから、高さを測る（折り返す文は、幅が決まるまで、1 行の高さになる）
        stack.layoutSubtreeIfNeeded()
        body.layoutSubtreeIfNeeded()
        let natural = ceil(body.fittingSize.height)
        let overflow = natural > Self.maxBodyHeight
        bodyHeight.constant = min(natural, Self.maxBodyHeight)
        stack.layoutSubtreeIfNeeded()
        if overflow { scroll.contentView.scroll(to: NSPoint(x: 0, y: natural - Self.maxBodyHeight)); scroll.reflectScrolledClipView(scroll.contentView) }
        // クリックを受けるのは、ボタン（確認）を出している間と、スクロールできる間だけ。ほかは、クリックを通す（パネルの下のアプリを、邪魔しない）。フォーカスは、奪わない（`nonactivatingPanel`）
        panel.ignoresMouseEvents = !(content.choices || overflow)

        updateKeyboard(panel, choices: content.choices)

        stack.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height)
        // いま使っている画面（マウスのある画面）の、上の中央
        let width = isCompact ? Self.compactWidth : Self.width
        let final = ScreenPlacement.hudFrame(in: ScreenPlacement.currentVisibleFrame(), width: width, height: height)
        panelHeight = height
        panelWidth = width

        if !visible {
            panel.setFrame(final.offsetBy(dx: 0, dy: 16), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            visible = true
            startFollowing()
        } else {
            // 出している「つもり」でも、Space の移動などで、いまの画面に出ていないことがある：毎回、前面へ出し直す（出ていれば、何も変わらない）
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            // 少し行き過ぎて、戻る（ばねのような出方）
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.25, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }

        if let hideAfter {
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, token == self.generation else { return }
                    self.fadeOut()
                }
            }
            pendingHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
        }
    }

    /// 出している間、0.3 秒ごとに、マウスのある画面を調べ、パネルが別の画面にあれば、その画面の上の中央へ移す。
    private func startFollowing() {
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followScreen() }
        }
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
    }

    /// Space を移ったとき：出している間は、移動先の画面の、上の中央へ、前面で出し直す。移動の動きが終わるころに、もう一度する（動きの途中に、順序が、無視されることがある）。
    private func reassertAfterSpaceChange() {
        reassertFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in MainActor.assumeIsolated { self?.reassertFront() } }
    }

    private func reassertFront() {
        guard visible, let panel else { return }
        panel.orderFrontRegardless()
        followScreen(force: true)
    }

    private func followScreen(force: Bool = false) {
        guard visible, let panel, let screen = ScreenPlacement.current() else { return }
        if !force && screen.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)) { return }   // すでに、その画面
        let target = ScreenPlacement.hudFrame(in: screen.visibleFrame, width: panelWidth, height: panelHeight)
        panel.setFrame(target, display: true)
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
            MainActor.assumeIsolated { self?.finishHide(token) }
        })
        // 完了の合図が来ないことがある（パネルが、いまの Space に出ていないとき）：来なくても、消す。消えないと、「出している」状態が残り、次の表示が、前面へ出ない
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in MainActor.assumeIsolated { self?.finishHide(token) } }
    }

    private func finishHide(_ token: Int) {
        guard token == generation, visible, let panel else { return }   // その間に、新しい表示が来ていれば、消さない
        panel.orderOut(nil)
        visible = false
        stopFollowing()
    }

    /// 確認を出している間だけ、キーを受ける（アプリは、前面にしない）。最初のフォーカスは「やめる」：ほかのアプリで打っている最中の Return が、実行にならないように。
    private func updateKeyboard(_ panel: HUDPanel, choices: Bool) {
        panel.onKey = { [weak self] event in MainActor.assumeIsolated { self?.handleKey(event) ?? false } }
        if choices, choiceButtons.count == 2 {
            panel.acceptsKeys = true
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(choiceButtons[1])
        } else if panel.acceptsKeys {
            panel.acceptsKeys = false
            if panel.isKeyWindow { panel.orderOut(nil); panel.orderFrontRegardless() }   // キーを、元のアプリへ返す
        }
    }

    /// ← → Tab：ボタンの間を移る。Return・Space：フォーカスのあるボタン。y：実行する。n・Esc：やめる。ほかのキーは、受けない。
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, panel.acceptsKeys, choiceButtons.count == 2,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let focused = choiceButtons.firstIndex { $0 === panel.firstResponder } ?? 1
        switch event.keyCode {
        case 123, 124, 48: panel.makeFirstResponder(choiceButtons[1 - focused])   // ← → Tab
        case 36, 76, 49: choiceButtons[focused].performClick(nil)                  // Return・Enter・Space
        case 53: answers.deliver(false)                                            // Esc
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "y": answers.deliver(true)
            case "n": answers.deliver(false)
            default: return false
            }
        }
        return true
    }

    /// パネルを、先に 1 回、画面に出して、すぐ消す（見えない）。**トリガー（Shift の長押しの、グローバルのキー監視）を入れる前に、呼ぶ**：
    /// 監視を入れたあとで、パネルを初めて出すと、そのパネルへ、マウスのクリックが届かない（実測：`vc listen --hotkey` の確認のボタン）。
    func warmUp() {
        ensurePanel()
        guard let panel, !visible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .vibrantDark)  // 背景の明るさに関わらず、同じ見た目
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassertAfterSpaceChange() }
        }

        let background = HUDStyle.glassBackground()

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
        ])
        let widthConstraint = stack.widthAnchor.constraint(equalToConstant: Self.width)
        widthConstraint.isActive = true
        // 光る縁（録音中・考え中・確認）。クリックは通す
        let glow = GlowBorderView(frame: .zero)
        glow.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(glow, positioned: .above, relativeTo: stack)
        NSLayoutConstraint.activate([
            glow.topAnchor.constraint(equalTo: background.topAnchor),
            glow.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            glow.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            glow.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        self.widthConstraint = widthConstraint
        self.glow = glow

        // 本文（スクロールできる）。見出しは、`render` が、この上に入れる
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: container.topAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: Self.rowWidth),
        ])
        let scroll = NSScrollView()
        scroll.documentView = container
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.verticalScrollElasticity = .none
        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        stack.addArrangedSubview(fixed(scroll))
        panel.contentView = background
        self.panel = panel
        self.background = background
        self.stack = stack
        self.body = body
        self.scroll = scroll
        self.bodyHeight = height
    }

    // MARK: 部品

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
        // 折り返して、`lines` 行を超えたら、最後の行を「…」で切る（`byTruncatingTail` だけだと、1 行に切られる）
        field.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = lines > 1
        field.preferredMaxLayoutWidth = Self.rowWidth
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// 確認のボタン：「実行する」「やめる」。押すと、答えを `answers` へ届ける（声の「はい」と、先に答えたほうが決まる）。
    private func choiceRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        func button(_ title: String, tint: NSColor?, yes: Bool) -> NSButton {
            let action = ButtonAction { [weak self] in self?.answers.deliver(yes) }
            buttonActions.append(action)
            let b = NSButton(title: title, target: action, action: #selector(ButtonAction.fire))
            b.bezelStyle = .rounded
            b.controlSize = .large
            b.bezelColor = tint
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 140).isActive = true
            return b
        }
        row.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 5, right: 4)   // フォーカスの枠が、切れないように
        choiceButtons = [button("実行する", tint: .systemGreen, yes: true), button("やめる", tint: nil, yes: false)]
        choiceButtons.forEach(row.addArrangedSubview)
        return row
    }

    private func header(_ content: HUDContent, accent: NSColor) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9

        if content.phase == .working {
            row.addArrangedSubview(ThinkingDotsView(tint: NSColor.systemTeal))
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
            if content.phase == .success || content.phase == .failure {
                // 出るとき、ぽんと弾む
                icon.wantsLayer = true
                let pop = CASpringAnimation(keyPath: "transform.scale")
                pop.fromValue = 0.4
                pop.toValue = 1.0
                pop.damping = 9
                pop.initialVelocity = 6
                pop.duration = pop.settlingDuration
                icon.layer?.add(pop, forKey: "pop")
            }
            row.addArrangedSubview(icon)
        }

        let title = NSTextField(labelWithString: content.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(title)

        if let skill = content.skill { row.addArrangedSubview(HUDStyle.pill(skill, fg: .systemTeal, bg: NSColor.systemTeal.withAlphaComponent(0.2))) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        if let chip = content.chip { row.addArrangedSubview(HUDStyle.pill(chip, fg: HUDStyle.secondary, bg: NSColor(white: 1, alpha: 0.12))) }
        return row
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
        result.textColor = HUDStyle.secondary
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

    /// 光る縁の色（回る）。録音中は赤〜橙、考え中は青〜紫、確認は黄。ほかは、なし。
    private static func glowColors(_ content: HUDContent) -> [NSColor]? {
        if content.choices { return [NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1), NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)] }
        switch content.phase {
        case .recording: return [NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1), NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1), NSColor(srgbRed: 1, green: 0.22, blue: 0.37, alpha: 1)]
        case .working: return [NSColor(srgbRed: 0.39, green: 0.82, blue: 1, alpha: 1), NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.37, green: 0.36, blue: 0.9, alpha: 1)]
        default: return nil
        }
    }

    /// 録音中・認識中の、小さなカプセルの中身。録音中：脈打つ点・波形・経過時間。認識中：考え中のドット・光る題。
    private func compactView(_ content: HUDContent) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let red = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
        if content.phase == .recording {
            row.addArrangedSubview(PulseDotView(tint: red))
            let wave = WaveformView(tint: red)
            wave.translatesAutoresizingMaskIntoConstraints = false
            wave.heightAnchor.constraint(equalToConstant: 28).isActive = true
            wave.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            waveform = wave
            row.addArrangedSubview(wave)
            row.addArrangedSubview(ElapsedLabel())
        } else {
            row.addArrangedSubview(ThinkingDotsView(tint: NSColor(srgbRed: 0.39, green: 0.82, blue: 1, alpha: 1)))
            let title = ShimmerLabel(content.title, font: .systemFont(ofSize: 15, weight: .semibold), color: .white)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(title)
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            row.addArrangedSubview(spacer)
        }
        if let chip = content.chip { row.addArrangedSubview(HUDStyle.pill(chip, fg: HUDStyle.secondary, bg: NSColor(white: 1, alpha: 0.12))) }

        guard let hint = content.hint else { return row }
        let column = NSStackView(views: [fixed(row, width: Self.compactRowWidth)])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = HUDStyle.secondary
        hintLabel.lineBreakMode = .byTruncatingTail
        column.addArrangedSubview(fixed(hintLabel, width: Self.compactRowWidth))
        return column
    }

    private func fixed(_ view: NSView, width: CGFloat) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }
}

/// パネル。確認を出している間だけ、キーを受ける（`nonactivatingPanel`：アプリを前面にせずに、キー入力を受けられる）。
private final class HUDPanel: NSPanel {
    var acceptsKeys = false
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { acceptsKeys }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

/// ボタンの動作（`NSButton` の target は、`NSObject` が要る）。
private final class ButtonAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// 上から下へ並べる（スクロールする本文の入れ物：短いときも、上に詰める）。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

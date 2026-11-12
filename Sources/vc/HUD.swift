import AppKit
import SwiftUI

/// 画面の上の中央に出す、小さなパネル（録音中・認識中・実行の経過・結果）。
/// クリックを通し、フォーカスを奪わない（操作の対象のアプリが、前面のまま）。画面の収録・アクセシビリティの許可は、要らない。
/// 中身は SwiftUI（`HUDSwiftUI.swift`：Liquid Glass のカード）。この型は、窓の管理（位置・フェード・Space・キー・クリックを通すか）だけ。
/// どのスレッドから呼んでもよい（`show`・`hide` は `nonisolated`：内部でメインスレッドへ回す）。呼び出し側のプロセスが、`NSApplication.run()` で動いていること。
/// 描画の状態は、メインアクターの上でだけ触る（`@MainActor`）。メインキューのブロックは、`assumeIsolated` で入る。
@MainActor final class HUD {
    typealias Mode = HUDContent.Phase

    nonisolated init() {}
    nonisolated static let shared = HUD()

    /// 「実行する」「やめる」のボタンの答えの届け先（確認を待っている処理が、つなぐ）。
    nonisolated let answers = AnswerRoute()

    private var panel: HUDPanel?
    private var host: NSHostingView<HUDRootView>?
    private let model = HUDModel()
    /// いま、確認のボタンを出しているか（キーで答えるのは、そのときだけ）。
    private var showingChoices = false
    private var bodyOverflows = false
    private var pendingHide: DispatchWorkItem?
    /// 出している間、マウスのある画面を見張る（別のディスプレイへ移ったら、パネルも、そこへ移る）。
    private var followTimer: Timer?
    /// カード（影の余白を除く）の大きさ。
    private var cardSize = NSSize(width: hudCardWidth, height: 60)
    private var visible = false
    private var generation = 0
    /// 仮想デスクトップ（Space）を移ったとき、出している間は、パネルを、移動先で出し直す。
    private var spaceObserver: NSObjectProtocol?
    private var previousPhase: Mode?

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
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { model.waveform.push(level) } }
    }

    /// 録音中に聞こえている文字（途中経過）を出す（録音のカプセルの 1 行）。録音の段階でなければ、何もしない。どのスレッドから呼んでもよい。
    nonisolated func pushLiveText(_ text: LiveCaptionText?) {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { if previousPhase == .recording || text == nil { model.liveText = text } } }
    }

    nonisolated func hide() {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { fadeOut() } }
    }

    // MARK: 描画（メインスレッド）

    private func render(_ content: HUDContent, hideAfter: TimeInterval?) {
        ensurePanel()
        guard let panel, let host else { return }
        pendingHide?.cancel()
        generation += 1
        if content.phase == .recording, previousPhase != .recording { model.beginRecording(); model.liveText = nil }
        if content.phase != .recording { model.liveText = nil }
        previousPhase = content.phase
        showingChoices = content.choices
        bodyOverflows = false
        model.focusedChoice = 1

        // 中身を差し替えて、すぐ、大きさを測る（SwiftUI の更新を待たずに、新しい中身の大きさを得る）
        host.rootView = HUDRootView(content: content, model: model, answer: { [weak self] yes in self?.answers.deliver(yes) })
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        cardSize = NSSize(width: size.width - 2 * hudShadowMargin, height: size.height - 2 * hudShadowMargin)

        // クリックを受けるのは、ボタン（確認）を出している間と、スクロールできる間だけ。ほかは、クリックを通す（パネルの下のアプリを、邪魔しない）。フォーカスは、奪わない（`nonactivatingPanel`）
        panel.ignoresMouseEvents = !content.choices
        updateKeyboard(panel, choices: content.choices)

        // いま使っている画面（マウスのある画面）の、上の中央
        let final = windowFrame(in: ScreenPlacement.currentVisibleFrame())

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

    /// 窓の枠：カードを、画面の上の中央に（上から 16pt）置いて、影の余白ぶん、広げる。
    private func windowFrame(in visible: NSRect) -> NSRect {
        ScreenPlacement.hudFrame(in: visible, width: cardSize.width, height: cardSize.height).insetBy(dx: -hudShadowMargin, dy: -hudShadowMargin)
    }

    /// 本文が、高さの上限を超えたとき（スクロールできる間は、クリックを受ける）。
    private func bodyOverflowChanged(_ overflows: Bool) {
        guard overflows != bodyOverflows else { return }
        bodyOverflows = overflows
        panel?.ignoresMouseEvents = !(showingChoices || overflows)
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
        panel.setFrame(windowFrame(in: screen.visibleFrame), display: true)
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
        showingChoices = false
        previousPhase = nil
        stopFollowing()
    }

    /// 確認を出している間だけ、キーを受ける（アプリは、前面にしない）。最初の選択は「やめる」：ほかのアプリで打っている最中の Return が、実行にならないように。
    private func updateKeyboard(_ panel: HUDPanel, choices: Bool) {
        panel.onKey = { [weak self] event in MainActor.assumeIsolated { self?.handleKey(event) ?? false } }
        if choices {
            panel.acceptsKeys = true
            panel.makeKeyAndOrderFront(nil)
        } else if panel.acceptsKeys {
            panel.acceptsKeys = false
            if panel.isKeyWindow { panel.orderOut(nil); panel.orderFrontRegardless() }   // キーを、元のアプリへ返す
        }
    }

    /// ← → Tab：ボタンの間を移る。Return・Space：選んでいるボタン。y：実行する。n・Esc：やめる。ほかのキーは、受けない。
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, panel.acceptsKeys, showingChoices,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 123, 124, 48: model.focusedChoice = 1 - model.focusedChoice      // ← → Tab
        case 36, 76, 49: answers.deliver(model.focusedChoice == 0)            // Return・Enter・Space
        case 53: answers.deliver(false)                                       // Esc
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
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: hudCardWidth + 2 * hudShadowMargin, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // 影は、カード（SwiftUI）が描く
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)  // 背景の明るさに関わらず、同じ見た目（ガラスも、暗いほう）
        // `.moveToActiveSpace`：前面へ出すたびに、いまの Space へ移る。`.canJoinAllSpaces` だと、長く動かしたあと、パネルのウィンドウだけが「いまの Space に属していない」状態で固まり、
        // 前面へ出しても、画面に出なくなることがあった（実測：動いている vc listen の中で、同じ設定の新しいパネルは出るのに、元のパネルだけが出なかった。`.moveToActiveSpace` に替えると、出た）。
        // Space を移ったときは、`reassertAfterSpaceChange` が、出している間のパネルを、移動先へ出し直す。
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassertAfterSpaceChange() }
        }
        model.onBodyOverflow = { [weak self] overflows in self?.bodyOverflowChanged(overflows) }
        let host = NSHostingView(rootView: HUDRootView(content: HUDContent(phase: .info, title: ""), model: model, answer: { _ in }))
        host.sizingOptions = [.intrinsicContentSize]   // 大きさを測るため（窓の最小・最大の大きさには、影響させない）。窓の大きさは、`render` が決める
        panel.contentView = host
        self.panel = panel
        self.host = host
    }
}

/// パネル。確認を出している間だけ、キーを受ける（`nonactivatingPanel`：アプリを前面にせずに、キー入力を受けられる）。
private final class HUDPanel: NSPanel {
    var acceptsKeys = false
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { acceptsKeys }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

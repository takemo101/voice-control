import AppKit
import Combine
import SwiftUI
import VCCore
import VCSkill
import VCSpeech

/// システム音声（相手の音声）の文字起こし（SPEC F80）の画面：**上のパネル（HUD）**に、波形と、聞こえている文字（音声入力と同じカプセル）。**真ん中のパネル**は、**チャットの形**（`TranscriptPanelView`）：相手の吹き出しが、時刻つきで並ぶ。
/// 開始・停止は、ショートカット（`transcribeHotkey`）か、パネルのボタン。自分の声は、ここではなく、音声入力（別のキー）。**文字起こし専用**：ここの文は、スキルを実行しない。
@MainActor final class TranscriptWindow: NSObject, NSWindowDelegate {
    static let shared = TranscriptWindow()
    let session = TranscriptSession()
    private var window: DocumentWindowFrame?
    private let panel = TranscriptPanelState()

    /// 開く（なければ、作る）。開始は、利用者が、ボタンかショートカットを押したときだけ（許可の確認が、その中で出る）。
    func show() {
        if window == nil { build() }
        refreshHints()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let frame = DocumentWindowFrame(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        frame.isReleasedWhenClosed = false
        frame.delegate = self
        frame.isOpaque = false
        frame.backgroundColor = .clear
        frame.hasShadow = true
        frame.appearance = NSAppearance(named: .darkAqua)
        frame.isMovableByWindowBackground = true
        frame.minSize = NSSize(width: 400, height: 420)
        frame.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = TranscriptPanelView(
            session: session, panel: panel,
            toggle: { [weak self] in self?.toggle() },
            copyMarkdown: { [weak self] in self?.copy(markdown: true) },
            copyText: { [weak self] in self?.copy(markdown: false) },
            copyOne: { Self.put($0) },
            clear: { [weak self] in self?.session.clear() },
            close: { [weak self] in self?.window?.close() })
        let hosting = NSHostingView(rootView: root.userScaled().environment(\.colorScheme, .dark))
        hosting.sizingOptions = []   // 中身（吹き出し）の大きさに、ウィンドウが引きずられない
        frame.contentView = hosting
        frame.setFrame(ScreenPlacement.windowFrame(size: NSSize(width: 560, height: 700), minSize: frame.minSize, in: ScreenPlacement.currentVisibleFrame()), display: false)
        window = frame
    }

    /// 空の画面の案内（ショートカット）と、取り込む音の名前を、いまの設定から。
    private func refreshHints() {
        let settings = Settings.loadOrDefault().settings
        panel.keyHint = settings.transcribeHotkey.flatMap { HotKeySpec.parse($0).successValue }?.displayName
        panel.targetName = (settings.transcribeApps ?? []).first
    }

    private static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copy(markdown: Bool) {
        Self.put(markdown ? session.log.markdown(title: tr("音声入力（システム）")) : MarkdownRenderer.plainText(session.log.panelMarkdown(showOriginal: false)))
        panel.copiedAll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.panel.copiedAll = false }
    }

    /// 開始・停止（ボタン）。**取り込みの開始は、利用者の操作**（許可の確認が出うる）。
    private func toggle() {
        Task { @MainActor in
            if session.isActive { await session.stop() } else { await start() }
        }
    }

    private func start() async {
        refreshHints()
        let settings = Settings.loadOrDefault().settings
        let chip = settings.transcribeHotkey.flatMap { HotKeySpec.parse($0).successValue }?.displayName
        await session.start(settings: settings, engine: Self.engine(for: settings), chip: chip)
    }

    /// ショートカット（設定 `transcribeHotkey`）：開始・停止。ほかのアプリの前面を、奪わない（Markdown のパネルは、前に出すだけ）。上のパネルに、波形と文字（止めたとき・始められないときは、その旨）。自分の声は、音声入力のキー（別）。
    func toggleFromShortcut() {
        if window == nil { build() }
        Task { @MainActor in
            if session.isActive {
                await session.stop()
                HUD.shared.show(HUDContent(phase: .info, title: tr("音声入力（システム）を止めました"), hint: tr("\(session.log.entries.count) 件")), hideAfter: 2)
                return
            }
            window?.orderFrontRegardless()
            await start()
            if case let .failed(why) = session.state {
                HUD.shared.show(HUDContent(phase: .failure, title: tr("音声入力（システム）を始められません"), hint: why), hideAfter: 5)
            }
        }
    }

    /// 整理に使う言語モデル（スキルを実行するモデル）。LAN のサーバーは、許可した場所だけ（なければ、Apple）。
    static func engine(for settings: VCCore.Settings) -> Engine {
        guard let engine = try? Engine.parse(settings.engine ?? "apple") else { return .apple }
        if let server = engine.server, !server.isApproved(by: settings.engineApproved) { return .apple }
        return engine
    }

    /// 閉じたら、止める（止め忘れて、取り込みが、続かないように）。`close()`（Esc・⌘W）でも、呼ばれる。
    func windowWillClose(_ notification: Notification) {
        if session.isActive { Task { @MainActor in await session.stop() } }
    }
}

private extension Result {
    var successValue: Success? { if case let .success(value) = self { return value } else { return nil } }
}

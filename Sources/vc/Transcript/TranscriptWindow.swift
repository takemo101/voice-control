import AppKit
import Combine
import SwiftUI
import VCCore
import VCSkill
import VCSpeech

/// システム音声（相手の音声）の文字起こし（SPEC F80）の画面：**上のパネル（HUD）**に、波形と、聞こえている文字（音声入力と同じカプセル）。**Markdown のパネル**に、確定した文が、時刻つきでたまる。
/// 開始・停止は、ショートカット（`transcribeHotkey`）か、Markdown のパネルのボタン。自分の声は、ここではなく、音声入力（別のキー）。**文字起こし専用**：ここの文は、スキルを実行しない。
/// 見た目は、Markdown のウィンドウと同じ（暗いガラスのカード：`DocumentView`）。
@MainActor final class TranscriptWindow: NSObject, NSWindowDelegate {
    static let shared = TranscriptWindow()
    let session = TranscriptSession()
    private var window: DocumentWindowFrame?
    private let textView = DiagramTextView()   // 図（Mermaid）は、クリックで拡大（Markdown のウィンドウと同じ）
    private let state = DocumentState()
    private var observers: [AnyCancellable] = []

    /// 開く（なければ、作る）。開始は、利用者が、ボタンかショートカットを押したときだけ（許可の確認が、その中で出る）。
    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let frame = DocumentWindowFrame(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        frame.isReleasedWhenClosed = false
        frame.delegate = self
        frame.isOpaque = false
        frame.backgroundColor = .clear
        frame.hasShadow = true
        frame.appearance = NSAppearance(named: .darkAqua)
        frame.isMovableByWindowBackground = true
        frame.minSize = NSSize(width: 380, height: 280)
        frame.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        configureTextView()
        frame.textView = textView
        let root = DocumentView(
            title: tr("相手の音声"), state: state, textView: textView,
            copyMarkdown: { [weak self] in self?.copy(markdown: true) },
            copyText: { [weak self] in self?.copy(markdown: false) },
            close: { [weak self] in self?.window?.close() },
            extra: AnyView(TranscriptToggle(session: session, toggle: { [weak self] in self?.toggle() })))
        let hosting = NSHostingView(rootView: root.userScaled().environment(\.colorScheme, .dark))
        hosting.sizingOptions = []   // 中身の大きさに、ウィンドウが引きずられない
        frame.contentView = hosting
        frame.setFrame(ScreenPlacement.windowFrame(size: NSSize(width: 640, height: 600), minSize: frame.minSize, in: ScreenPlacement.currentVisibleFrame()), display: false)
        window = frame
        // 確定した文・整理後の置き換え・状態が変わったら、本文を組み直す（確定前の文字は、上のパネルだけ：ここでは、組み直さない）
        observers = [
            session.$log.sink { [weak self] log in MainActor.assumeIsolated { self?.render(log) } },
            session.$state.sink { [weak self] _ in MainActor.assumeIsolated { self?.render(self?.session.log) } },
            UIScale.shared.$size.dropFirst().sink { [weak self] _ in MainActor.assumeIsolated { self?.render(self?.session.log) } },
        ]
    }

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
    }

    /// 本文：文がなければ、案内。あれば、時刻つきの文（最後へ、スクロール）。
    private func render(_ log: TranscriptLog?) {
        guard let log else { return }
        let body: String
        if log.entries.isEmpty {
            switch session.state {
            case .running, .starting: body = "*\(tr("音が出るのを、待っています…"))*"
            default: body = "*\(tr("ショートカットか「開始」で、Mac から出ている音（相手の音声）を、文字にします。"))*"
            }
        } else {
            body = log.panelMarkdown()
        }
        textView.textStorage?.setAttributedString(MarkdownRenderer.render(body))
        if !log.entries.isEmpty { textView.scrollToEndOfDocument(nil) }
    }

    private func copy(markdown: Bool) {
        let text = markdown ? session.log.markdown(title: tr("相手の音声")) : MarkdownRenderer.plainText(session.log.panelMarkdown(showOriginal: false))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let button: DocumentState.Button = markdown ? .markdown : .text
        state.copied = button
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in if self?.state.copied == button { self?.state.copied = nil } }
    }

    /// 開始・停止（ボタン）。**取り込みの開始は、利用者の操作**（許可の確認が出うる）。
    private func toggle() {
        Task { @MainActor in
            if session.isActive { await session.stop() } else { await start() }
        }
    }

    private func start() async {
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

/// Markdown のパネルの下の行に足す、「開始・停止」と、状態（始められない理由）。
private struct TranscriptToggle: View {
    @ObservedObject var session: TranscriptSession
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PillButton(title: session.isActive ? tr("停止") : tr("開始"), symbol: session.isActive ? "stop.fill" : "record.circle", flashed: false, action: toggle)
            if case let .failed(why) = session.state { Text(why).vcFont(11).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: 220, alignment: .leading) }
            if let notice = session.notice { Text(notice).vcFont(11).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: 220, alignment: .leading) }
        }
    }
}

private extension Result {
    var successValue: Success? { if case let .success(value) = self { return value } else { return nil } }
}

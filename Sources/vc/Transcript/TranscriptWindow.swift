import AppKit
import SwiftUI
import VCCore
import VCSkill
import VCSpeech

/// 文字起こしのウィンドウ（SPEC F80）：システム音声（相手）と、設定によっては、マイク（自分）を、文にして、時系列で出す。開始・停止・コピー（Markdown）。
/// 見た目は、Markdown のウィンドウと同じ（暗いガラスのカード）。**文字起こし専用**：ここの文は、スキルを実行しない。
@MainActor final class TranscriptWindow: NSObject, NSWindowDelegate {
    static let shared = TranscriptWindow()
    let session = TranscriptSession()
    private var window: DocumentWindowFrame?
    private let state = DocumentState()

    /// 開く（なければ、作る）。開始は、利用者が、ウィンドウの「開始」を押したときだけ（許可の確認が、その中で出る）。
    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let frame = DocumentWindowFrame(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        frame.isReleasedWhenClosed = false
        frame.delegate = self
        frame.isOpaque = false
        frame.backgroundColor = .clear
        frame.hasShadow = true
        frame.appearance = NSAppearance(named: .darkAqua)
        frame.isMovableByWindowBackground = true
        frame.minSize = NSSize(width: 380, height: 320)
        frame.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = TranscriptView(session: session, state: state,
                                  toggle: { [weak self] in self?.toggle() },
                                  copy: { [weak self] in self?.copyMarkdown() },
                                  clear: { [weak self] in self?.session.clear() },
                                  close: { [weak self] in self?.window?.close() })
        let hosting = NSHostingView(rootView: root.userScaled().environment(\.colorScheme, .dark))
        hosting.sizingOptions = []   // 中身（一覧）の大きさに、ウィンドウが引きずられない
        frame.contentView = hosting
        frame.setFrame(ScreenPlacement.windowFrame(size: NSSize(width: 600, height: 640), minSize: frame.minSize, in: ScreenPlacement.currentVisibleFrame()), display: false)
        window = frame
    }

    /// 開始・停止（ウィンドウのボタン）。**取り込みの開始は、利用者の操作**（許可の確認が出うる）。
    private func toggle() {
        Task { @MainActor in
            if session.isActive { await session.stop() } else { await start() }
        }
    }

    private func start() async {
        let settings = Settings.loadOrDefault().settings
        await session.start(settings: settings, engine: Self.engine(for: settings))
    }

    /// ショートカット（設定 `transcribeHotkey`）：開始・停止。ほかのアプリの前面を、奪わない（ウィンドウは、前に出すだけ）。結果は、画面の上のパネルに出す（失敗の理由も）。自分の声は、音声入力のキー（別）。
    func toggleFromShortcut() {
        if window == nil { build() }
        Task { @MainActor in
            if session.isActive {
                await session.stop()
                HUD.shared.show(HUDContent(phase: .info, title: tr("文字起こし（相手の音声）を止めました"), hint: tr("\(session.log.entries.count) 件")), hideAfter: 2)
                return
            }
            window?.orderFrontRegardless()
            await start()
            if case let .failed(why) = session.state {
                HUD.shared.show(HUDContent(phase: .failure, title: tr("文字起こし（相手の音声）を始められません"), hint: why), hideAfter: 5)
            } else {
                HUD.shared.show(HUDContent(phase: .info, title: tr("文字起こし（相手の音声）を始めました"), hint: tr("もう一度押すと、止めます")), hideAfter: 2)
            }
        }
    }

    /// 整理に使う言語モデル（スキルを実行するモデル）。LAN のサーバーは、許可した場所だけ（なければ、Apple）。
    static func engine(for settings: VCCore.Settings) -> Engine {
        guard let engine = try? Engine.parse(settings.engine ?? "apple") else { return .apple }
        if let server = engine.server, !server.isApproved(by: settings.engineApproved) { return .apple }
        return engine
    }

    private func copyMarkdown() {
        let markdown = session.log.markdown(title: tr("文字起こし"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        state.copied = .markdown
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.state.copied = nil }
    }

    /// 閉じたら、止める（止め忘れて、取り込みが、続かないように）。`close()`（Esc・⌘W）でも、呼ばれる。
    func windowWillClose(_ notification: Notification) {
        if session.isActive { Task { @MainActor in await session.stop() } }
    }
}

private struct TranscriptView: View {
    @ObservedObject var session: TranscriptSession
    @ObservedObject var state: DocumentState
    let toggle: () -> Void
    let copy: () -> Void
    let clear: () -> Void
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 0) {
            header
            Rule()
            list
            Rule()
            footer
        }
        .glassEffect(.regular.tint(DocumentPalette.accent.opacity(0.06)), in: shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.05), DocumentPalette.accent.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .clipShape(shape)
    }

    private var statusText: String {
        switch session.state {
        case .idle: return tr("止まっています")
        case .starting: return tr("始めています…")
        case .running: return tr("文字にしています")
        case let .failed(why): return why
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(DocumentPalette.accent.opacity(0.2)).frame(width: 28, height: 28)
                    Image(systemName: session.state == .running ? "waveform" : "waveform.slash").vcFont(13, weight: .semibold).foregroundStyle(DocumentPalette.accent)
                }
                Text(tr("文字起こし（相手の音声）")).vcFont(15, weight: .semibold).foregroundStyle(.white)
                Text(statusText).vcFont(11, weight: .medium).foregroundStyle({ if case .failed = session.state { return Color.orange }; return .white.opacity(0.6) }()).lineLimit(2)
                Spacer(minLength: 8)
                Button(action: close) { Image(systemName: "xmark.circle.fill").vcFont(20).foregroundStyle(.white.opacity(0.45)) }.buttonStyle(.plain).accessibilityLabel(tr("閉じる"))
            }
            // 同意の注意（いつも出す）。自分の声は、音声入力（別のキー）
            Text(tr("Mac から出ている音を、文字にします。録音・文字起こしには、相手の同意が要る場合があります。自分の声は、音声入力のキーで、入力します。"))
                .vcFont(10.5).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(DragArea())
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if session.log.entries.isEmpty && session.log.tentative == nil {
                        Text(session.isActive ? tr("音が出るのを、待っています…") : tr("「開始」を押すと、Mac から出ている音を、文字にします。"))
                            .vcFont(13).foregroundStyle(.white.opacity(0.5)).padding(.top, 24).frame(maxWidth: .infinity)
                    }
                    ForEach(session.log.entries) { entry in EntryRow(entry: entry) }
                    if let text = session.log.tentative { TentativeRow(text: text) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .onChange(of: session.log.entries.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: session.log.tentative) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = session.notice { Text(notice).vcFont(11).foregroundStyle(.orange) }
            HStack(spacing: 10) {
                PillButton(title: session.isActive ? tr("停止") : tr("開始"), symbol: session.isActive ? "stop.fill" : "record.circle", flashed: false, action: toggle)
                PillButton(title: tr("Markdown をコピー"), symbol: "doc.on.doc", flashed: state.copied == .markdown, action: copy)
                PillButton(title: tr("消す"), symbol: "trash", flashed: false, action: clear)
                Spacer(minLength: 8)
                PillButton(title: tr("閉じる  esc"), symbol: "xmark", flashed: false, cancel: true, action: close)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(DragArea())
    }
}

private struct EntryRow: View {
    let entry: TranscriptLog.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.date.formatted(date: .omitted, time: .standard)).vcFont(10.5).foregroundStyle(.white.opacity(0.4))
            Text(entry.text).vcFont(14).foregroundStyle(.white.opacity(0.95)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let raw = entry.raw { Text(tr("元：\(raw)")).vcFont(11).foregroundStyle(.white.opacity(0.4)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct TentativeRow: View {
    let text: String
    var body: some View {
        Text(text).vcFont(14).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)   // 確定前：薄く
    }
}

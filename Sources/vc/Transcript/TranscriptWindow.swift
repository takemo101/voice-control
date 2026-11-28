import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
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
        let root = TranscriptPanelView(session: session, panel: panel, actions: TranscriptPanelActions(
            toggle: { [weak self] in self?.toggle() },
            toggleMic: { [weak self] in self?.toggleMic() },
            copyMarkdown: { [weak self] in self?.copy(markdown: true) },
            copyText: { [weak self] in self?.copy(markdown: false) },
            copyOne: { Self.put($0) },
            saveMarkdown: { [weak self] in self?.saveMarkdown() },
            saveSubtitles: { [weak self] vtt in self?.saveSubtitles(vtt: vtt) },
            newMeeting: { [weak self] in self?.newMeeting() },
            summarize: { [weak self] scope, ids in self?.summarize(scope, ids) },
            delete: { [weak self] id in self?.delete(id) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            close: { [weak self] in self?.window?.close() }))
        let hosting = NSHostingView(rootView: root.userScaled().environment(\.colorScheme, .dark))
        hosting.sizingOptions = []   // 中身（吹き出し）の大きさに、ウィンドウが引きずられない
        frame.contentView = hosting
        frame.setFrame(ScreenPlacement.windowFrame(size: NSSize(width: 560, height: 700), minSize: frame.minSize, in: ScreenPlacement.currentVisibleFrame()), display: false)
        window = frame
    }

    /// 見た目の確認用（`vc transcript-preview --demo --summary`）：要約の面を開く。
    func openSummaryTabForPreview() { panel.tab = .summary }

    /// 空の画面の案内（ショートカット）と、取り込む音の名前を、いまの設定から。
    private func refreshHints() {
        let settings = Settings.loadOrDefault().settings
        panel.keyHint = settings.transcribeHotkey.flatMap { HotKeySpec.parse($0).successValue }?.displayName
        panel.targetName = (settings.transcribeApps ?? []).first
        panel.micOn = settings.transcribeMic ?? false
    }

    private static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copy(markdown: Bool) {
        Self.put(markdown ? session.document().markdown() : session.log.plainText())
        panel.copiedAll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.panel.copiedAll = false }
    }

    // MARK: 保存・字幕・新しい会議・要約・削除（F81・F82）

    /// 保存のパネル（利用者が、場所を選ぶ）。選んだ場所へ、書く。
    private func save(_ text: String, name: String, extensionName: String) {
        let dialog = NSSavePanel()
        dialog.nameFieldStringValue = name
        dialog.allowedContentTypes = UTType(filenameExtension: extensionName).map { [$0] } ?? []
        dialog.canCreateDirectories = true
        if let folder = Settings.loadOrDefault().settings.meetingFolder?.trimmingCharacters(in: .whitespaces), !folder.isEmpty {
            dialog.directoryURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        }
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        do { try MeetingWriter.writeFile(text, to: url) } catch { _ = AppAlerts.confirm(title: tr("保存できませんでした"), message: "\(error)", confirm: tr("閉じる"), cancel: nil, style: .warning) }
    }

    private func saveMarkdown() {
        let document = session.document()
        save(document.markdown(), name: document.fileName, extensionName: "md")
    }

    /// 字幕（SRT・VTT）：1 つの発話を 1 つの字幕に。話し手の名前つき。
    private func saveSubtitles(vtt: Bool) {
        let document = session.document()
        let base = (document.fileName as NSString).deletingPathExtension
        save(vtt ? Subtitles.vtt(document.entries) : Subtitles.srt(document.entries), name: base + (vtt ? ".vtt" : ".srt"), extensionName: vtt ? "vtt" : "srt")
    }

    /// 新しい会議：画面の記録・要約を、消す（履歴・書いたファイルは、残る）。
    private func newMeeting() {
        guard !session.isActive else { return }
        let hasText = !session.log.entries.isEmpty || !session.summaries.isEmpty
        if hasText, !AppAlerts.confirm(title: tr("新しい会議にしますか？"), message: tr("いまの画面の記録と要約が、消えます（履歴と、書いたファイルは、残ります）。"), confirm: tr("新しい会議にする"), style: .warning) { return }
        session.clear()
        panel.stopSelecting()
        panel.openOriginals = []
    }

    /// 要約（会議全体・選んだ発話・テーマ）。設定（要約の指示・モデル）は、いまのものを読む。
    private func summarize(_ scope: MeetingSummary.Scope, _ ids: Set<UUID>?) {
        let settings = Settings.loadOrDefault().settings
        Task { @MainActor in
            panel.tab = .summary   // 結果が、見えるように
            await session.summarize(scope, entryIDs: ids, settings: settings, engine: Self.engine(for: settings))
            if ids != nil { panel.stopSelecting() }
        }
    }

    /// 発話を 1 件消す（確認のあと）：画面の記録・履歴・書いたファイルから。
    private func delete(_ id: UUID) {
        guard AppAlerts.confirm(title: tr("この発話を消しますか？"), message: tr("画面の記録と、履歴（あれば）から、消えます。消した発話は、戻せません。"), confirm: tr("消す"), style: .warning) else { return }
        panel.selected.remove(id)
        session.delete(entryID: id)
    }

    /// 自分のマイクの入り切り（パネルの上のボタン）：設定 `transcribeMic` を書き換えて、動いている間なら、すぐ、入れる・外す。
    private func toggleMic() {
        let loaded = Settings.loadOrDefault()
        guard loaded.problem == nil else { return }   // 読めない設定を、上書きしない
        var settings = loaded.settings
        let on = !(settings.transcribeMic ?? false)
        settings.transcribeMic = on ? true : nil
        do { try settings.save() } catch { HUD.shared.show(HUDContent(phase: .failure, title: tr("設定を保存できませんでした"), hint: "\(error)"), hideAfter: 3); return }
        NotificationCenter.default.post(name: DictationActions.settingsChanged, object: nil)
        panel.micOn = on
        Task { @MainActor in await session.setMic(on, settings: settings) }
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
                HUD.shared.show(HUDContent(phase: .info, title: tr("音声入力（会議）を止めました"), hint: tr("\(session.log.entries.count) 件")), hideAfter: 2)
                return
            }
            window?.orderFrontRegardless()
            await start()
            if case let .failed(why) = session.state {
                HUD.shared.show(HUDContent(phase: .failure, title: tr("音声入力（会議）を始められません"), hint: why), hideAfter: 5)
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

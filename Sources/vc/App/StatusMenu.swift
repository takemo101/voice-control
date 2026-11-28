import AppKit
import Combine
import VCCore

/// メニューバーの項目。メニューは、開くたびに、状態から作り直す。
@MainActor final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let runtime: AppRuntime
    private var token: AnyObject?
    private var sessionSink: AnyCancellable?

    init(runtime: AppRuntime) {
        self.runtime = runtime
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        token = runtime.observe { [weak self] in self?.refreshIcon() }
        // 記録中の目印：会議の文字起こしが動いている間は、アイコンが変わる（止め忘れの防止。F81）
        // `$state` は、値が変わる**前**に届く：`session.isActive` を読むと、ひとつ前の状態になる（止めても、赤いままになる）。届いた値を、使う
        let session = TranscriptWindow.shared.session
        recording = session.isActive
        sessionSink = session.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.recording = (state == .starting || state == .running); self?.refreshIcon() }
        }
        refreshIcon()
    }

    /// 会議の文字起こしが動いているか（アイコンを赤くする）。
    private var recording = false

    private func refreshIcon() {
        guard let button = item.button else { return }
        let (symbol, label): (String, String)
        switch runtime.state {
        case .starting: (symbol, label) = ("ellipsis.circle", tr("準備中"))
        case .listening: (symbol, label) = ("mic.fill", tr("聞いています"))
        case .stopped: (symbol, label) = ("mic.slash", tr("停止中"))
        }
        if recording {
            // 文字起こし中：赤い丸（テンプレートでは、色が付かない）
            let recording = tr("会議を文字にしています")
            let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "vc: \(recording)")?.withSymbolConfiguration(configuration)
            image?.isTemplate = false
            button.image = image
            button.toolTip = "vc: \(recording)"
            return
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "vc: \(label)")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "vc: \(label)"
    }

    // MARK: メニュー

    /// 見た目の確認用（`vc menu-preview`）：メニューに出す状態を、決め打ちにする（なければ、実際の状態）。
    var previewState: AppRuntime.State?

    /// 開くたびに、状態から作り直す。**よく使うものだけ**を、上に：状態・（あれば）更新・会話・会議・音声入力・設定・終了。診断・データのフォルダ・コマンド vc・更新の確認・会話のリセットは、設定ウィンドウ・会話のウィンドウにある（ここには置かない）。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        refreshIcon()   // 表示の言語を切り替えたあとの、アイコンの読み上げ・ヒントも、開くたびに合わせる
        menu.removeAllItems()
        let state = previewState ?? runtime.state
        menu.addItem(statusItem(for: state))
        if case .stopped = state { menu.addItem(action(tr("もう一度、始める"), #selector(retry))) }
        switch UpdateModel.shared.phase {
        case let .available(release): menu.addItem(action(tr("新しいバージョン \(release.version) に更新…"), #selector(installUpdate)))
        case .checking: menu.addItem(label(tr("更新を確認しています…")))
        case .preparing: menu.addItem(label(tr("更新を準備しています…")))
        default: break
        }
        menu.addItem(.separator())
        if SaySpeaker.shared.isSpeaking() { menu.addItem(action(tr("読み上げを止める"), #selector(stopSpeaking))) }
        menu.addItem(action(tr("会話を開く"), #selector(openChat)))
        if TranscriptWindow.shared.session.isActive {
            menu.addItem(action(tr("会議の文字起こしを止める"), #selector(stopTranscript)))
        } else {
            menu.addItem(action(tr("音声入力（会議）を開く"), #selector(openTranscript)))
        }
        let dictation = NSMenuItem(title: tr("音声入力（マイク）"), action: nil, keyEquivalent: "")
        dictation.submenu = dictationMenu()
        menu.addItem(dictation)
        menu.addItem(.separator())
        menu.addItem(action(tr("設定…"), #selector(openSettings), key: ","))
        menu.addItem(NSMenuItem(title: tr("終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// 状態の 1 行（題と補足）。補足：聞いているときは、キーの案内・止まっているときは、理由。
    private func statusItem(for state: AppRuntime.State) -> NSMenuItem {
        let (title, detail): (String, String?)
        switch state {
        case .starting: (title, detail) = (tr("準備中"), nil)
        case let .listening(hint): (title, detail) = (tr("聞いています"), hint)
        case let .stopped(reason): (title, detail) = (tr("停止中"), String(reason.prefix(60)) + (reason.count > 60 ? "…" : ""))
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")   // 行き先なし・有効のまま：文字が薄くならない
        item.subtitle = detail
        item.toolTip = "voice-control \(AppInfo.version)"
        return item
    }

    /// 音声入力（マイク）の操作：直前の入力の貼り直し・直近の入力のコピー・入力のあとに送るキーの切り替え。
    private func dictationMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let recent = RecentDictations.shared.recent
        let pasteItem = action(tr("直前の入力を貼り直す"), #selector(pasteLastDictation))
        pasteItem.isEnabled = !recent.isEmpty
        menu.addItem(pasteItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: tr("最近の入力（選ぶとコピー）")))
        for text in recent {
            let item = NSMenuItem(title: Self.excerpt(text), action: #selector(copyDictation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = text
            menu.addItem(item)
        }
        if recent.isEmpty { menu.addItem(label(tr("まだ入力がありません"))) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: tr("入力のあとに送るキー")))
        let send = Settings.loadOrDefault().settings.dictateSend
        for (index, mode) in send.modes.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(chooseSendMode(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = index == send.active ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: 操作

    @objc private func retry() { runtime.start() }

    @objc private func installUpdate() { UpdateModel.shared.confirmAndInstall() }

    /// メニューの題に出す、入力の抜粋（1 行・短く）。
    private static func excerpt(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    /// 貼り直す：メニューが閉じて、前面のアプリに、フォーカスが戻ってから。
    @objc private func pasteLastDictation() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))   // try?: 取りやめられたら、そのまま続ける（待つだけ）
            await DictationActions.pasteLast(paste: DictationActions.menuPaste, settings: Settings.loadOrDefault().settings)
        }
    }

    @objc private func copyDictation(_ sender: NSMenuItem) { if let text = sender.representedObject as? String { DictationActions.copy(text) } }

    @objc private func chooseSendMode(_ sender: NSMenuItem) { DictationActions.setSendMode(sender.tag) }

    @objc private func openChat() { ChatWindow.shared.show(activate: true) }
    @objc private func openTranscript() { TranscriptWindow.shared.show() }
    @objc private func stopTranscript() { TranscriptWindow.shared.toggleFromShortcut() }

    @objc private func stopSpeaking() { SaySpeaker.shared.stop() }

    @objc private func openSettings() { SettingsWindow.shared.show() }

    /// 見た目の確認用：メニューを、開く。
    func openForPreview() { item.button?.performClick(nil) }

    /// 見た目の確認用：「音声入力（マイク）」の中身だけを、画面の中ほどに、開く。
    func openDictationForPreview() { dictationMenu().popUp(positioning: nil, at: NSPoint(x: 400, y: 600), in: nil) }
}

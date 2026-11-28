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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        refreshIcon()   // 表示の言語を切り替えたあとの、アイコンの読み上げ・ヒントも、開くたびに合わせる
        menu.removeAllItems()
        menu.addItem(label("voice-control \(AppInfo.version)"))
        switch runtime.state {
        case .starting: menu.addItem(label(tr("状態: 準備中")))
        case let .listening(hint): menu.addItem(label(tr("状態: 聞いています"))); menu.addItem(label(hint))
        case let .stopped(reason):
            menu.addItem(label(tr("状態: 停止中")))
            menu.addItem(label(String(reason.prefix(60)) + (reason.count > 60 ? "…" : "")))
            menu.addItem(action(tr("もう一度、始める"), #selector(retry)))
        }
        switch UpdateModel.shared.phase {
        case let .available(release): menu.addItem(action(tr("新しいバージョン \(release.version) に更新…"), #selector(installUpdate)))
        case .checking: menu.addItem(label(tr("更新を確認しています…")))
        case .preparing: menu.addItem(label(tr("更新を準備しています…")))
        default: menu.addItem(action(tr("更新を確認"), #selector(checkUpdate)))
        }
        menu.addItem(.separator())
        if SaySpeaker.shared.isSpeaking() { menu.addItem(action(tr("読み上げを止める"), #selector(stopSpeaking))) }
        // 音声入力：直前の入力の貼り直し・直近の入力のコピー・入力のあとに送るキーの切り替え
        let recent = RecentDictations.shared.recent
        let pasteItem = action(tr("直前の入力を貼り直す"), #selector(pasteLastDictation))
        pasteItem.isEnabled = !recent.isEmpty
        menu.addItem(pasteItem)
        let copyItem = NSMenuItem(title: tr("最近の入力をコピー"), action: nil, keyEquivalent: "")
        let copyMenu = NSMenu()
        for text in recent {
            let item = NSMenuItem(title: Self.excerpt(text), action: #selector(copyDictation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = text
            copyMenu.addItem(item)
        }
        if recent.isEmpty { copyMenu.addItem(label(tr("まだ入力がありません"))) }
        copyItem.submenu = copyMenu
        menu.addItem(copyItem)
        let sendItem = NSMenuItem(title: tr("入力のあとに送るキー"), action: nil, keyEquivalent: "")
        let sendMenu = NSMenu()
        let send = Settings.loadOrDefault().settings.dictateSend
        for (index, mode) in send.modes.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(chooseSendMode(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = index == send.active ? .on : .off
            sendMenu.addItem(item)
        }
        sendItem.submenu = sendMenu
        menu.addItem(sendItem)
        menu.addItem(.separator())
        if TranscriptWindow.shared.session.isActive { menu.addItem(action(tr("会議の文字起こしを止める"), #selector(stopTranscript))) }
        menu.addItem(action(tr("音声入力（会議）を開く"), #selector(openTranscript)))
        menu.addItem(action(tr("会話を開く"), #selector(openChat)))
        menu.addItem(action(tr("会話をリセット"), #selector(resetConversation)))
        menu.addItem(action(tr("診断…"), #selector(showDoctor)))
        menu.addItem(action(tr("設定…"), #selector(openSettings), key: ","))
        menu.addItem(action(tr("データのフォルダを開く（スキル・設定）"), #selector(openDataFolder)))
        menu.addItem(commandItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

    /// コマンド `vc`（`/usr/local/bin` へのリンク）を、入れる・外す。入っていれば、チェック。
    private func commandItem() -> NSMenuItem {
        let tool = CommandLineTool()
        switch tool.state {
        case .unavailable: return label(tr("コマンド「vc」: アプリを「アプリケーション」へ移すと入れられます"))
        case let .other(path): return label(tr("コマンド「vc」: \(path) に、別のものがあります"))
        case .installed:
            let item = action(tr("コマンド「vc」をインストール（/usr/local/bin）"), #selector(toggleCommand))
            item.state = .on
            return item
        case .stale: return action(tr("コマンド「vc」を、このアプリへ付け替える"), #selector(toggleCommand))
        case .notInstalled: return action(tr("コマンド「vc」をインストール（/usr/local/bin）"), #selector(toggleCommand))
        }
    }

    // MARK: 操作

    @objc private func retry() { runtime.start() }

    @objc private func installUpdate() { UpdateModel.shared.confirmAndInstall() }

    /// 手で確認する：結果を、上のパネルで知らせる（新しい版があれば、次にメニューを開いたとき、更新の項目が出る）。
    @objc private func checkUpdate() {
        Task {
            await UpdateModel.shared.check(manual: true)
            let model = UpdateModel.shared
            switch model.phase {
            case let .available(release): HUD.shared.show(HUDContent(phase: .info, title: tr("新しいバージョン \(release.version) があります"), hint: tr("メニューバーの「更新」から、入れられます"), chip: tr("更新")), hideAfter: 5)
            case let .failed(why): AppAlerts.show(title: tr("更新を確認できません"), message: why, style: .warning)
            default: HUD.shared.show(HUDContent(phase: .success, title: tr("最新の版です"), hint: "voice-control \(model.currentVersion)", chip: tr("更新")), hideAfter: 2.5)
            }
        }
    }

    @objc private func resetConversation() { AppActions.resetConversation() }

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

    @objc private func showDoctor() { AppActions.showDoctor() }

    @objc private func openSettings() { SettingsWindow.shared.show() }

    @objc private func openDataFolder() { AppActions.openDataFolder() }

    @objc private func toggleCommand() {
        if let problem = AppActions.toggleCommandLine() { AppAlerts.show(title: tr("コマンドを変えられません"), message: problem, style: .warning) }
    }
}

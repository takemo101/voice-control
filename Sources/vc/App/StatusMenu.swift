import AppKit
import VCCore

/// メニューバーの項目。メニューは、開くたびに、状態から作り直す。
@MainActor final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let runtime: AppRuntime
    private var token: AnyObject?

    init(runtime: AppRuntime) {
        self.runtime = runtime
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        token = runtime.observe { [weak self] in self?.refreshIcon() }
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = item.button else { return }
        let (symbol, label): (String, String)
        switch runtime.state {
        case .starting: (symbol, label) = ("ellipsis.circle", tr("準備中"))
        case .listening: (symbol, label) = ("mic.fill", tr("聞いています"))
        case .stopped: (symbol, label) = ("mic.slash", tr("停止中"))
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

    @objc private func openChat() { ChatWindow.shared.show(activate: true) }

    @objc private func stopSpeaking() { SaySpeaker.shared.stop() }

    @objc private func showDoctor() { AppActions.showDoctor() }

    @objc private func openSettings() { SettingsWindow.shared.show() }

    @objc private func openDataFolder() { AppActions.openDataFolder() }

    @objc private func toggleCommand() {
        if let problem = AppActions.toggleCommandLine() { AppAlerts.show(title: tr("コマンドを変えられません"), message: problem, style: .warning) }
    }
}

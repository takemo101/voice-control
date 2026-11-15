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
        case .starting: (symbol, label) = ("ellipsis.circle", "準備中")
        case .listening: (symbol, label) = ("mic.fill", "聞いています")
        case .stopped: (symbol, label) = ("mic.slash", "停止中")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "vc: \(label)")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "vc: \(label)"
    }

    // MARK: メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        menu.addItem(label("voice-control \(AppInfo.version)"))
        switch runtime.state {
        case .starting: menu.addItem(label("状態: 準備中"))
        case let .listening(hint): menu.addItem(label("状態: 聞いています")); menu.addItem(label(hint))
        case let .stopped(reason):
            menu.addItem(label("状態: 停止中"))
            menu.addItem(label(String(reason.prefix(60)) + (reason.count > 60 ? "…" : "")))
            menu.addItem(action("もう一度、始める", #selector(retry)))
        }
        menu.addItem(.separator())
        menu.addItem(action("診断…", #selector(showDoctor)))
        menu.addItem(action("設定…", #selector(openSettings), key: ","))
        menu.addItem(action("データのフォルダを開く（スキル・設定）", #selector(openDataFolder)))
        menu.addItem(loginItem())
        menu.addItem(commandItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

    private func loginItem() -> NSMenuItem {
        let item = action("ログイン時に起動", #selector(toggleLogin))
        item.state = AppActions.loginItemEnabled ? .on : .off
        return item
    }

    /// コマンド `vc`（`/usr/local/bin` へのリンク）を、入れる・外す。入っていれば、チェック。
    private func commandItem() -> NSMenuItem {
        let tool = CommandLineTool()
        switch tool.state {
        case .unavailable: return label("コマンド「vc」: アプリを「アプリケーション」へ移すと入れられます")
        case let .other(path): return label("コマンド「vc」: \(path) に、別のものがあります")
        case .installed:
            let item = action("コマンド「vc」をインストール（/usr/local/bin）", #selector(toggleCommand))
            item.state = .on
            return item
        case .stale: return action("コマンド「vc」を、このアプリへ付け替える", #selector(toggleCommand))
        case .notInstalled: return action("コマンド「vc」をインストール（/usr/local/bin）", #selector(toggleCommand))
        }
    }

    // MARK: 操作

    @objc private func retry() { runtime.start() }

    @objc private func showDoctor() { AppActions.showDoctor() }

    @objc private func openSettings() { SettingsWindow.shared.show() }

    @objc private func openDataFolder() { AppActions.openDataFolder() }

    @objc private func toggleLogin() {
        if let problem = AppActions.setLoginItem(!AppActions.loginItemEnabled) { AppAlerts.show(title: "ログイン時の起動を変えられません", message: problem, style: .warning) }
    }

    @objc private func toggleCommand() {
        if let problem = AppActions.toggleCommandLine() { AppAlerts.show(title: "コマンドを変えられません", message: problem, style: .warning) }
    }
}

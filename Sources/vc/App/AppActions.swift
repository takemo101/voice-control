import AppKit
import Foundation
import ServiceManagement
import VCCore

/// メニューと設定ウィンドウが、共通に使う操作。
@MainActor enum AppActions {
    /// アプリを開き直す（設定を変えたあと）。アプリの中の実行ファイルでなければ（ビルドしたまま）、手で開き直すよう案内する。
    static func relaunch() {
        guard let executable = AppLaunch.executablePath, let bundle = AppLaunch.bundlePath(forExecutable: executable) else {
            AppAlerts.show(title: "開き直せません", message: "アプリ（VoiceControl.app）として動いていません。手で、終了してから、開き直してください。", style: .informational)
            return
        }
        // 終了したあとに、開く（開いたままだと、同じアプリの起動が、いまのアプリに吸収される）。このプロセスが終わっても、子は、続く
        let script = "sleep 0.8; /usr/bin/open \(CommandLineTool.shellQuote(bundle))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do { try process.run() } catch {
            AppAlerts.show(title: "開き直せません", message: error.localizedDescription, style: .warning)
            return
        }
        NSApp.terminate(nil)
    }

    static var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// ログイン時の起動を切り替える。失敗なら、利用者に見せる理由。
    static func toggleLoginItem() -> String? {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
            return nil
        } catch { return error.localizedDescription }
    }

    /// システム設定の「プライバシーとセキュリティ」の、その項目を開く（`pane`：`Privacy_Microphone`・`Privacy_Accessibility`・`Privacy_ScreenCapture`）。
    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// 診断（`vc doctor`）を、ウィンドウに出す。アプリ自身が動かすので、許可の状態は、このアプリのもの。
    static func showDoctor() {
        guard let executable = Bundle.main.executablePath else { return }
        Task.detached {
            let result = ProcessRunner.run(executable: executable, arguments: ["doctor"], mergeStderr: true, timeout: 30)
            await MainActor.run {
                if let why = DocumentWindow.present(markdown: "```\n" + result.text + "\n```", title: "vc doctor") { AppAlerts.show(title: "診断を出せません", message: why, style: .warning) }
            }
        }
    }

    static func openSettingsFile() {
        let file = VoiceControlHome.settingsFile
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) } else { NSWorkspace.shared.open(VoiceControlHome.root) }
    }

    static func openDataFolder() { NSWorkspace.shared.open(VoiceControlHome.root) }

    /// コマンド `vc` を、入れる・外す。失敗なら、利用者に見せる理由。
    static func toggleCommandLine() -> String? {
        let tool = CommandLineTool()
        return tool.state == .installed ? tool.uninstall() : tool.install()
    }
}

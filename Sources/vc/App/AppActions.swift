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

    enum LoginItemState: Equatable {
        case on
        case off
        /// 登録したが、システム設定（ログイン項目）での承認が要る。
        case needsApproval
        /// アプリの場所などの都合で、登録できない（ビルドしたまま・「アプリケーション」の外など）。
        case unavailable
    }

    static var loginItemState: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        default: return .off
        }
    }

    /// 会話の記録を消す（メモリだけの記録。声で「会話を終わって」と言うのと同じ）。
    static func resetConversation() {
        Task {
            await ChatMode.shared.end()
            HUD.shared.show(HUDContent(phase: .info, title: "会話をリセットしました", hint: "次の会話は、新しく始まります"), hideAfter: 2.5)
        }
    }

    static var loginItemEnabled: Bool { loginItemState == .on || loginItemState == .needsApproval }

    /// ログイン時の起動を、オン・オフにする。失敗なら、利用者に見せる理由。
    static func setLoginItem(_ on: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if on { if service.status != .enabled { try service.register() } } else { try service.unregister() }
            return nil
        } catch { return error.localizedDescription }
    }

    /// アクセシビリティの許可を、リセットして、設定を開く（更新のあとで、許可が「オンなのに効かない」ときの、付け直し）。失敗なら、利用者に見せる理由。
    /// このアプリの bundle ID の許可だけを消す（`tccutil reset`）。ほかのアプリの許可は、触らない。
    static func resetAccessibility() -> String? {
        guard let id = Bundle.main.bundleIdentifier else { return "アプリとして動いていません" }
        let result = ProcessRunner.run(executable: "tccutil", arguments: ["reset", "Accessibility", id], mergeStderr: true, timeout: 10)
        guard result.exitCode == 0 else { return result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "tccutil が失敗しました（\(result.exitCode)）" : result.text }
        openPrivacy("Privacy_Accessibility")
        return nil
    }

    /// システム設定の「ログイン項目」を開く。
    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// システム設定の「プライバシーとセキュリティ」の、その項目を開く（`pane`：`Privacy_Microphone`・`Privacy_Accessibility`・`Privacy_ScreenCapture`）。
    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// 診断（`vc doctor` と同じ確認）を、ウィンドウに出す。アプリ自身が確かめるので、許可の状態は、このアプリのもの。
    static func showDoctor() { DiagnosticsWindow.shared.show() }

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

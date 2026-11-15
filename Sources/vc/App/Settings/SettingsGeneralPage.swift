import AppKit
import SwiftUI
import VCCore
import VCDecision
import VCSkill
import VCSpeech

// MARK: 一般

struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    /// 準備の 1 項目。
    private struct Step {
        let title: String
        let detail: String
        let done: Bool
        let action: (label: String, run: () -> Void)?
    }

    private func steps() -> [Step] {
        let mic = MicRecorder.permission
        var list: [Step] = [
            Step(title: "マイクの許可", detail: mic == .granted ? "許可されています" : "声を聞くために必要です。アプリを起動すると、確認が出ます", done: mic == .granted,
                 action: mic == .granted ? nil : ("許可する", { AppActions.openPrivacy("Privacy_Microphone") })),
            Step(title: "アクセシビリティの許可", detail: ModifierHold.isTrusted ? "許可されています" : "キー（修飾キーの長押し・Esc）の検出と、前面のアプリへの入力に必要です", done: ModifierHold.isTrusted,
                 action: ModifierHold.isTrusted ? nil : ("許可する", { AppActions.openPrivacy("Privacy_Accessibility") })),
            Step(title: "Tiny-Jev のモデル", detail: model.isInstalled(TinyJevModel.spec) ? "取得済みです" : "スキルを選ぶモデル（約 1.2 GB）。取得が必要です", done: model.isInstalled(TinyJevModel.spec),
                 action: model.isInstalled(TinyJevModel.spec) ? nil : ("取得する", { model.page = .models })),
        ]
        if model.settings.engine == nil, case let .unavailable(reason) = AppleIntelligence.current() {
            list.append(Step(title: "Apple Intelligence", detail: reason.summary + "。" + reason.remedy, done: false, action: ("システム設定を開く", { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) })))
        }
        return list
    }

    var body: some View {
        let _ = model.revision
        let steps = steps()
        let pending = steps.filter { !$0.done }.count
        Card("準備状況", footer: "許可は、このアプリ自身に付きます（ターミナルには、よりません）。変えたら、右上の「もう一度、確かめる」。") {
            Row(pending == 0 ? "準備ができています" : "あと \(pending) 件で、使えます", detail: pending == 0 ? "声の入力を使えます" : "下の項目を、上から順に、片づけてください") {
                HStack(spacing: 10) {
                    SettingsPill(text: pending == 0 ? "OK" : "要設定", color: pending == 0 ? Brand.ok : Brand.warn)
                    Button("もう一度、確かめる") { model.reload() }.controlSize(.small)
                }
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                RowDivider()
                Row(step.title, detail: step.detail) {
                    HStack(spacing: 10) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "exclamationmark.circle.fill").font(.system(size: 16)).foregroundStyle(step.done ? Brand.ok : Brand.warn)
                        if let action = step.action { Button(action.label) { action.run() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small) }
                    }
                }
            }
        }
        Card("起動", footer: "オンにすると、Mac にログインしたときに、voice-control が、メニューバーで、自動で起動します。") {
            LoginRow(model: model)
        }
        Card("ターミナル") {
            CommandLineRow(model: model)
        }
        Card("情報") {
            Row("診断", detail: "必要なものが、そろっているかを、くわしく確かめます") { Button("開く") { AppActions.showDoctor() }.controlSize(.small) }
            RowDivider()
            Row("画面収録の許可", detail: "画面撮影・画面を見るスキルを使うときだけ必要です") {
                HStack(spacing: 10) {
                    SettingsPill(text: ScreenCapture.isAllowed ? "許可済み" : "許可なし", color: ScreenCapture.isAllowed ? Brand.ok : Color.secondary)
                    Button("開く") { AppActions.openPrivacy("Privacy_ScreenCapture") }.controlSize(.small)
                }
            }
            RowDivider()
            Row("設定ファイル", detail: "~/.voice-control/settings.json") { Button("開く") { AppActions.openSettingsFile() }.controlSize(.small) }
            RowDivider()
            Row("データのフォルダ", detail: "スキル・設定・モデル") { Button("開く") { AppActions.openDataFolder() }.controlSize(.small) }
            RowDivider()
            Row("バージョン", detail: "voice-control") { Text(AppInfo.version).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
        }
    }
}

struct LoginRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let state = AppActions.loginItemState
        let message = model.loginMessage
        VStack(alignment: .leading, spacing: 6) {
            Row("ログイン時に起動", detail: state == .unavailable ? "このアプリの場所では、登録できません。「アプリケーション」フォルダへ移してください" : nil) {
                HStack(spacing: 10) {
                    if state == .needsApproval { SettingsPill(text: "承認が必要", color: Brand.warn) }
                    BrandSwitch(isOn: Binding(get: { AppActions.loginItemEnabled }, set: { on in
                        model.setLoginItem(on)
                    }))
                    .opacity(state == .unavailable ? 0.4 : 1).disabled(state == .unavailable)
                }
            }
            if state == .needsApproval {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Brand.warn)
                    Text("システム設定の「ログイン項目」で、voice-control を許可してください。").font(.system(size: 11))
                    Spacer()
                    Button("ログイン項目を開く") { AppActions.openLoginItemsSettings() }.controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
    }
}

struct CommandLineRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let tool = CommandLineTool()
        let installed = tool.state == .installed
        Row("ターミナルのコマンド「vc」", detail: "スキルが使うコマンド（vc show・vc skills など）を、ターミナルから使えます。/usr/local/bin にリンクを置きます（管理者のパスワードを求められることがあります）") {
            switch tool.state {
            case .unavailable: Text("アプリを「アプリケーション」へ移すと入れられます").font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing).frame(width: 150)
            case let .other(path): Text("\(path) に、別のものがあります").font(.system(size: 11)).foregroundStyle(Brand.warn).multilineTextAlignment(.trailing).frame(width: 150)
            case .installed, .notInstalled, .stale:
                HStack(spacing: 8) {
                    if installed { SettingsPill(text: "インストール済み", color: Brand.ok) }
                    Button(installed ? "外す" : (tool.state == .notInstalled ? "インストール" : "付け替える")) {
                        if let problem = AppActions.toggleCommandLine() { AppAlerts.show(title: "コマンドを変えられません", message: problem, style: .warning) }
                        model.reload()
                    }.controlSize(.small)
                }
            }
        }
    }
}

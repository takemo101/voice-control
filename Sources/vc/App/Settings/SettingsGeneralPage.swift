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
        /// 補助の操作（小さいボタン）。
        var secondary: (label: String, run: () -> Void)? = nil
    }

    private func steps() -> [Step] {
        let mic = MicRecorder.permission
        var list: [Step] = [
            Step(title: "マイクの許可", detail: mic == .granted ? "許可されています" : "声を聞くために必要です。アプリを起動すると、確認が出ます", done: mic == .granted,
                 action: mic == .granted ? nil : ("許可する", { AppActions.openPrivacy("Privacy_Microphone") })),
            Step(title: "アクセシビリティの許可", detail: ModifierHold.isTrusted ? "許可されています" : "キー（修飾キーの長押し・Esc）の検出と、前面のアプリへの入力に必要です", done: ModifierHold.isTrusted,
                 action: ModifierHold.isTrusted ? nil : ("許可する", { AppActions.openPrivacy("Privacy_Accessibility") }),
                 secondary: ModifierHold.isTrusted ? nil : ("オンなのに効かない", { resetAccessibility() })),
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
                        if let secondary = step.secondary { Button(secondary.label) { secondary.run() }.controlSize(.small).help("更新のあとなどで、設定は「オン」なのに、効かないとき：このアプリの許可を、リセットして、付け直します") }
                        if let action = step.action { Button(action.label) { action.run() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small) }
                    }
                }
            }
        }
        Card("起動", footer: "オンにすると、Mac にログインしたときに、voice-control が、メニューバーで、自動で起動します。") {
            LoginRow(model: model)
        }
        Card("表示", footer: "会話・Markdown のウィンドウ・上のパネル・画像の窓の、文字の大きさです（標準は 13）。この設定ウィンドウは、変わりません。開いている画面も、すぐ変わります。") {
            Row("文字の大きさ", detail: "10 〜 24") {
                HStack(spacing: 10) {
                    if (model.settings.fontSize ?? UIScale.standard) != UIScale.standard {
                        Button("標準に戻す") { model.setFontSize(UIScale.standard) }.controlSize(.small)
                    }
                    FontSizeStepper(value: model.settings.fontSize ?? UIScale.standard) { model.setFontSize($0) }
                }
            }
        }
        Card("アップデート", footer: "確認は、起動時と 1 日ごとに、GitHub の公開情報（最新のリリース）を取りに行くだけで、あなたのデータは、送りません。入れるのは、あなたが選んだときだけです（取得したファイルは、SHA-256 と署名を確かめてから、入れ替えます）。") {
            SwitchRow(model: model, title: "新しい版を、自動で確認する", detail: "見つけたら、上のパネルとメニューで、知らせます", value: model.settings.updateCheck ?? true) { $0.updateCheck = $1 }
            RowDivider()
            UpdateRow()
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

extension GeneralPage {
    /// 許可を、リセットして、付け直す（確認のあとで）。
    @MainActor fileprivate func resetAccessibility() {
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = "アクセシビリティの許可を、リセットしますか？"
        alert.informativeText = "設定で「オン」なのに効かないときの、付け直しです。このアプリの許可だけを消して、システム設定を開きます。開いたら、voice-control を、もう一度、オンにして、「もう一度、確かめる」を押してください。"
        alert.addButton(withTitle: "リセットして、設定を開く")
        alert.addButton(withTitle: "やめる")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let problem = AppActions.resetAccessibility() { AppAlerts.show(title: "リセットできません", message: problem, style: .warning) }
    }
}

/// 更新の行：いまの版・状態・操作（確認する・更新する）。
struct UpdateRow: View {
    @ObservedObject private var update = UpdateModel.shared

    var body: some View {
        let phase = update.phase
        Row("バージョン \(update.currentVersion)", detail: detail(phase)) {
            HStack(spacing: 8) {
                switch phase {
                case .checking: ProgressView().controlSize(.small)
                case let .preparing(fraction):
                    if let fraction { ProgressView(value: fraction).frame(width: 90) } else { ProgressView().controlSize(.small) }
                case let .available(release):
                    Button("変更点") { NSWorkspace.shared.open(release.pageURL) }.controlSize(.small)
                    Button("\(release.version.description) に更新…") { update.confirmAndInstall() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small)
                default:
                    Button("更新を確認") { Task { await update.check(manual: true) } }.controlSize(.small)
                }
            }
        }
    }

    private func detail(_ phase: UpdateModel.Phase) -> String {
        switch phase {
        case .idle: return update.lastChecked.map { "最後の確認：\($0.formatted(date: .omitted, time: .shortened))" } ?? "まだ、確認していません"
        case .checking: return "確認しています…"
        case .upToDate: return "最新の版です"
        case let .available(release): return "新しい版（\(release.version)）があります"
        case let .preparing(fraction): return fraction.map { "取得しています…（\(Int($0 * 100))%）" } ?? "検証しています…"
        case let .failed(why): return why
        }
    }
}

/// 「−  13  +」の形の、文字の大きさの操作（押し続けると、続けて変わる）。
struct FontSizeStepper: View {
    let value: Int
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", help: "小さく", enabled: value > UIScale.range.lowerBound) { set(value - 1) }
            Text("\(value)").font(.system(size: 14, weight: .medium).monospacedDigit()).frame(minWidth: 40)
            stepButton("plus", help: "大きく", enabled: value < UIScale.range.upperBound) { set(value + 1) }
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
    }

    private func stepButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 34, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35).help(help)
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

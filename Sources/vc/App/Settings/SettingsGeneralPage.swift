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
            Step(title: tr("マイクの許可"), detail: mic == .granted ? tr("許可されています") : tr("声を聞くために必要です。アプリを起動すると、確認が出ます"), done: mic == .granted,
                 action: mic == .granted ? nil : (tr("許可する"), { AppActions.openPrivacy("Privacy_Microphone") })),
            Step(title: tr("アクセシビリティの許可"), detail: ModifierHold.isTrusted ? tr("許可されています") : tr("キー（修飾キーの長押し・Esc）の検出と、前面のアプリへの入力に必要です"), done: ModifierHold.isTrusted,
                 action: ModifierHold.isTrusted ? nil : (tr("許可する"), { AppActions.openPrivacy("Privacy_Accessibility") }),
                 secondary: ModifierHold.isTrusted ? nil : (tr("オンなのに効かない"), { resetAccessibility() })),
            Step(title: tr("Tiny-Jev のモデル"), detail: model.isInstalled(TinyJevModel.spec) ? tr("取得済みです") : tr("スキルを選ぶモデル（約 1.2 GB）。取得が必要です"), done: model.isInstalled(TinyJevModel.spec),
                 action: model.isInstalled(TinyJevModel.spec) ? nil : (tr("取得する"), { model.page = .models })),
        ]
        if model.settings.engine == nil, case let .unavailable(reason) = AppleIntelligence.current() {
            list.append(Step(title: "Apple Intelligence", detail: reason.summary + "。" + reason.remedy, done: false, action: (tr("システム設定を開く"), { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) })))
        }
        return list
    }

    var body: some View {
        let _ = model.revision
        let steps = steps()
        let pending = steps.filter { !$0.done }.count
        Card(tr("準備状況"), footer: tr("許可は、このアプリ自身に付きます（ターミナルには、よりません）。変えたら、右上の「もう一度、確かめる」。")) {
            Row(pending == 0 ? tr("準備ができています") : tr("あと \(pending) 件で、使えます"), detail: pending == 0 ? tr("声の入力を使えます") : tr("下の項目を、上から順に、片づけてください")) {
                HStack(spacing: 10) {
                    SettingsPill(text: pending == 0 ? "OK" : tr("要設定"), color: pending == 0 ? Brand.ok : Brand.warn)
                    Button(tr("もう一度、確かめる")) { model.reload() }.controlSize(.small)
                }
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                RowDivider()
                Row(step.title, detail: step.detail) {
                    HStack(spacing: 10) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "exclamationmark.circle.fill").font(.system(size: 16)).foregroundStyle(step.done ? Brand.ok : Brand.warn)
                        if let secondary = step.secondary { Button(secondary.label) { secondary.run() }.controlSize(.small).help(tr("更新のあとなどで、設定は「オン」なのに、効かないとき：このアプリの許可を、リセットして、付け直します")) }
                        if let action = step.action { Button(action.label) { action.run() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small) }
                    }
                }
            }
        }
        Card(tr("基本"), footer: tr("表示言語は、設定ウィンドウとダイアログの言葉です（音声認識の言語は、設定 > 音声）。文字の大きさは、会話・Markdown・上のパネル・画像の窓に効きます（標準は 13。この設定ウィンドウは、変わりません）。")) {
            LoginRow(model: model)
            RowDivider()
            Row(tr("表示言語"), detail: tr("設定ウィンドウとダイアログ")) {
                Picker("", selection: Binding(get: { model.uiLanguage }, set: { model.setUILanguage($0) })) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            RowDivider()
            Row(tr("文字の大きさ"), detail: "10 〜 24") {
                HStack(spacing: 10) {
                    if (model.settings.fontSize ?? UIScale.standard) != UIScale.standard {
                        Button(tr("標準に戻す")) { model.setFontSize(UIScale.standard) }.controlSize(.small)
                    }
                    FontSizeStepper(value: model.settings.fontSize ?? UIScale.standard) { model.setFontSize($0) }
                }
            }
        }
        Card(tr("アップデート"), footer: tr("確認は、起動時と 1 日ごとに、GitHub の公開情報（最新のリリース）を取りに行くだけで、あなたのデータは、送りません。入れるのは、あなたが選んだときだけです（取得したファイルは、SHA-256 と署名を確かめてから、入れ替えます）。")) {
            SwitchRow(model: model, title: tr("新しい版を、自動で確認する"), detail: tr("見つけたら、上のパネルとメニューで、知らせます"), value: model.settings.updateCheck ?? true) { $0.updateCheck = $1 }
            RowDivider()
            UpdateRow()
        }
        Card(tr("ツール・情報")) {
            CommandLineRow(model: model)
            RowDivider()
            Row(tr("診断"), detail: tr("必要なものが、そろっているかを、くわしく確かめます")) { Button(tr("開く")) { AppActions.showDoctor() }.controlSize(.small) }
            RowDivider()
            Row(tr("画面収録の許可"), detail: tr("画面撮影・画面を見るスキルを使うときだけ必要です")) {
                HStack(spacing: 10) {
                    SettingsPill(text: ScreenCapture.isAllowed ? tr("許可済み") : tr("許可なし"), color: ScreenCapture.isAllowed ? Brand.ok : Color.secondary)
                    Button(tr("開く")) { AppActions.openPrivacy("Privacy_ScreenCapture") }.controlSize(.small)
                }
            }
            RowDivider()
            Row(tr("設定ファイル"), detail: "~/.voice-control/settings.json") { Button(tr("開く")) { AppActions.openSettingsFile() }.controlSize(.small) }
            RowDivider()
            Row(tr("データのフォルダ"), detail: tr("スキル・設定・モデル")) { Button(tr("開く")) { AppActions.openDataFolder() }.controlSize(.small) }
            RowDivider()
            Row(tr("バージョン"), detail: "voice-control") { Text(AppInfo.version).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
        }
    }
}

extension GeneralPage {
    /// 許可を、リセットして、付け直す（確認のあとで）。
    @MainActor fileprivate func resetAccessibility() {
        let message = tr("設定で「オン」なのに効かないときの、付け直しです。このアプリの許可だけを消して、システム設定を開きます。開いたら、voice-control を、もう一度、オンにして、「もう一度、確かめる」を押してください。")
        guard AppAlerts.confirm(title: tr("アクセシビリティの許可を、リセットしますか？"), message: message, confirm: tr("リセットして、設定を開く")) else { return }
        if let problem = AppActions.resetAccessibility() { AppAlerts.show(title: tr("リセットできません"), message: problem, style: .warning) }
    }
}

/// 更新の行：いまの版・状態・操作（確認する・更新する）。
struct UpdateRow: View {
    @ObservedObject private var update = UpdateModel.shared

    var body: some View {
        let phase = update.phase
        Row(tr("バージョン \(update.currentVersion)"), detail: detail(phase)) {
            HStack(spacing: 8) {
                switch phase {
                case .checking: ProgressView().controlSize(.small)
                case let .preparing(fraction):
                    if let fraction { ProgressView(value: fraction).frame(width: 90) } else { ProgressView().controlSize(.small) }
                case let .available(release):
                    Button(tr("変更点")) { NSWorkspace.shared.open(release.pageURL) }.controlSize(.small)
                    Button(tr("\(release.version.description) に更新…")) { update.confirmAndInstall() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small)
                default:
                    Button(tr("更新を確認")) { Task { await update.check(manual: true) } }.controlSize(.small)
                }
            }
        }
    }

    private func detail(_ phase: UpdateModel.Phase) -> String {
        switch phase {
        case .idle: return update.lastChecked.map { tr("最後の確認：\($0.formatted(date: .omitted, time: .shortened))") } ?? tr("まだ、確認していません")
        case .checking: return tr("確認しています…")
        case .upToDate: return tr("最新の版です")
        case let .available(release): return tr("新しい版（\(release.version)）があります")
        case let .preparing(fraction): return fraction.map { tr("取得しています…（\(Int($0 * 100))%）") } ?? tr("検証しています…")
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
            stepButton("minus", help: tr("小さく"), enabled: value > UIScale.range.lowerBound) { set(value - 1) }
            Text("\(value)").font(.system(size: 14, weight: .medium).monospacedDigit()).frame(minWidth: 40)
            stepButton("plus", help: tr("大きく"), enabled: value < UIScale.range.upperBound) { set(value + 1) }
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
            Row(tr("ログイン時に起動"), detail: state == .unavailable ? tr("このアプリの場所では、登録できません。「アプリケーション」フォルダへ移してください") : nil) {
                HStack(spacing: 10) {
                    if state == .needsApproval { SettingsPill(text: tr("承認が必要"), color: Brand.warn) }
                    BrandSwitch(isOn: Binding(get: { AppActions.loginItemEnabled }, set: { on in
                        model.setLoginItem(on)
                    }))
                    .opacity(state == .unavailable ? 0.4 : 1).disabled(state == .unavailable)
                }
            }
            if state == .needsApproval {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Brand.warn)
                    Text(tr("システム設定の「ログイン項目」で、voice-control を許可してください。")).font(.system(size: 11))
                    Spacer()
                    Button(tr("ログイン項目を開く")) { AppActions.openLoginItemsSettings() }.controlSize(.small)
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
        Row(tr("ターミナルのコマンド「vc」"), detail: tr("スキルが使うコマンド（vc show・vc skills など）を、ターミナルから使えます。/usr/local/bin にリンクを置きます（管理者のパスワードを求められることがあります）")) {
            switch tool.state {
            case .unavailable: Text(tr("アプリを「アプリケーション」へ移すと入れられます")).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing).frame(width: 150)
            case let .other(path): Text(tr("\(path) に、別のものがあります")).font(.system(size: 11)).foregroundStyle(Brand.warn).multilineTextAlignment(.trailing).frame(width: 150)
            case .installed, .notInstalled, .stale:
                HStack(spacing: 8) {
                    if installed { SettingsPill(text: tr("インストール済み"), color: Brand.ok) }
                    Button(installed ? tr("外す") : (tool.state == .notInstalled ? tr("インストール") : tr("付け替える"))) {
                        if let problem = AppActions.toggleCommandLine() { AppAlerts.show(title: tr("コマンドを変えられません"), message: problem, style: .warning) }
                        model.reload()
                    }.controlSize(.small)
                }
            }
        }
    }
}

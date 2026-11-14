import AppKit
import SwiftUI
import VCCore
import VCDecision
import VCSkill
import VCSpeech

/// 設定ウィンドウ（meeting-analyzer の設定ウィンドウと同じ作り：左にページ・右に設定）。閉じても、アプリは終了しない。
@MainActor final class SettingsWindow {
    static let shared = SettingsWindow()
    private let model = SettingsModel()
    private var window: NSWindow?

    func show() {
        model.reload()
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "voice-control の設定"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let _ = model.revision
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: Binding<SettingsPage?>(get: { model.page }, set: { if let page = $0 { model.page = page } })) { page in
                Label(page.title, systemImage: page.symbol).font(.system(size: 13)).padding(.vertical, 3).tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            Divider()
            VStack(spacing: 0) {
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.needsRestart {
                    HStack {
                        Label("変えた設定を反映するには、再起動が要ります", systemImage: "arrow.clockwise.circle")
                        Spacer()
                        Button("今すぐ再起動") { AppActions.relaunch() }
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.12))
                }
                Form {
                    switch model.page {
                    case .keys: KeysPage(model: model)
                    case .voice: VoicePage(model: model)
                    case .models: ModelsPage(model: model)
                    case .skills: SkillsPage(model: model)
                    case .general: GeneralPage(model: model)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 780, height: 580)
    }
}

// MARK: キー

private struct KeysPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("キー（押している間だけ話す）") {
            ForEach(KeyKind.allCases, id: \.self) { kind in KeyRow(model: model, kind: kind) }
        }
        Section("操作") {
            Toggle("ダブルタップで、黙るまで録音する（手放し）", isOn: Binding(get: { model.settings.handsFree ?? true }, set: { value in model.update { $0.handsFree = value } }))
            Text("キーを短く 2 回押すと、黙るまで録音します（押し続ける使い方は、そのまま使えます）。").font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Text("修飾キーだけのキー（shift・ctrl・rcmd・ropt など）の長押しは、アクセシビリティの許可が要ります（「一般」で確認できます）。キーの書き方：shift・ctrl+opt+space・f5・rcmd（右の Command）など。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct KeyRow: View {
    @ObservedObject var model: SettingsModel
    let kind: KeyKind

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(kind.title)
                Spacer()
                TextField("", text: Binding(get: { model.keyDrafts[kind] ?? "" }, set: { model.setDraft(kind, $0) }), prompt: Text(kind.isOptional ? "（使わない）" : "shift"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { model.commitKey(kind) }
                Menu("候補") {
                    ForEach(kind.presets, id: \.self) { preset in
                        Button(preset) { model.setDraft(kind, preset); model.commitKey(kind) }
                    }
                    if kind.isOptional {
                        Divider()
                        Button("使わない") { model.setDraft(kind, ""); model.commitKey(kind) }
                    }
                }
                .fixedSize()
                Button("適用") { model.commitKey(kind) }.disabled(model.keyProblems[kind] != nil || (model.keyDrafts[kind] ?? "") == (model.settings[keyPath: kind.keyPath] ?? ""))
            }
            Text(kind.help).font(.caption).foregroundStyle(.secondary)
            if let problem = model.keyProblems[kind] { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 2)
    }
}

// MARK: 音声

private struct VoicePage: View {
    @ObservedObject var model: SettingsModel

    private func toggle(_ title: String, _ value: Bool, _ set: @escaping (inout VCCore.Settings, Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { newValue in model.update { set(&$0, newValue) } }))
    }

    var body: some View {
        Section("録音") {
            toggle("録音中に、ほかの音を消す", model.settings.mute ?? true) { $0.mute = $1 }
            toggle("録音中に、聞こえている文字を、画面の上に出す（実験）", model.settings.liveCaption ?? true) { $0.liveCaption = $1 }
            toggle("聞き取りに自信がないとき、実行の前に、確かめる（実験）", model.settings.recheck ?? true) { $0.recheck = $1 }
        }
        Section("読み上げ") {
            toggle("実行の結果を、声で読み上げる（確認の問いかけは、いつも読み上げます）", model.settings.speakResults ?? false) { $0.speakResults = $1 }
            Picker("声", selection: Binding(get: { model.settings.voice ?? "" }, set: { value in model.update { $0.voice = value.isEmpty ? nil : value } })) {
                Text("自動（入っている日本語の声のうち、品質が最も高いもの）").tag("")
                ForEach(SpeechVoice.installed().sorted { ($0.quality, $1.identifier) > ($1.quality, $0.identifier) }, id: \.identifier) { voice in
                    Text(voice.name).tag(voice.identifier)
                }
            }
            Button("試しに読む") { say("声の確認です。こんにちは。") }
        }
        Section("音声入力のつなぎ言葉") {
            toggle("音声入力で、つなぎ言葉（えーと・um など）を消す", model.settings.removeFillers ?? false) { $0.removeFillers = $1 }
            Text("消す言葉（1 行に 1 つ。空にすると、既定の辞書）").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.fillersText).font(.system(size: 12)).frame(height: 90).border(Color.secondary.opacity(0.3))
            HStack {
                Button("保存") { model.saveFillers() }
                Button("既定に戻す") { model.resetFillers() }
            }
        }
    }
}

// MARK: モデル

private struct ModelsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("スキルを実行するモデル") {
            Picker("エンジン", selection: Binding(get: { model.engineKind }, set: { model.setEngine(kind: $0, rest: $0 == .apple ? "" : model.engineRest) })) {
                ForEach(SettingsRules.EngineKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if model.engineKind != .apple {
                TextField("モデル", text: Binding(get: { model.engineRest }, set: { model.setEngine(kind: model.engineKind, rest: $0) }), prompt: Text(model.engineKind.placeholder)).textFieldStyle(.roundedBorder)
                if let problem = model.engineProblem { Text(problem).font(.caption).foregroundStyle(.red) }
                Text("この Mac のサーバー（127.0.0.1）だけ使えます。クラウドのモデルは、使えません。サーバーが動いているかは、「一般」の診断で確かめられます。").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("1 つの依頼を、複数のステップに分けて実行する（実験）", isOn: Binding(get: { model.settings.multiStep ?? true }, set: { value in model.update { $0.multiStep = value } }))
        }
        Section("会話") {
            Picker("会話に使うエージェント", selection: Binding(get: { model.settings.chatAgent ?? "apple" }, set: { value in model.update { $0.chatAgent = value == "apple" ? nil : value } })) {
                ForEach(ChatAgent.allCases, id: \.rawValue) { agent in Text(agent.label).tag(agent.rawValue) }
            }
            if let name = model.settings.chatAgent, ChatAgent.parse(name)?.isExternal == true {
                Label("会話の発話が、この Mac の外（そのエージェントの提供元）へ送られます。画像・コピーした文章は、渡しません。", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        Section("音声認識") {
            Picker("使う音声認識", selection: Binding(get: { model.settings.stt ?? "apple" }, set: { model.setSTT($0) })) {
                ForEach(model.sttChoices, id: \.id) { Text($0.title).tag($0.id) }
            }
        }
        Section("モデルの取得（取得だけが、外部との通信です。音声・画面は、送りません）") {
            ModelRow(model: model, id: TinyJevModel.spec.name, title: "Tiny-Jev 0.6B（スキルの選択。必須）", spec: TinyJevModel.spec, deletable: false)
            ForEach(SpeechModelCatalog.all, id: \.id) { entry in
                ModelRow(model: model, id: entry.id, title: "\(entry.name)（音声認識）", spec: entry.spec, deletable: true)
            }
        }
    }
}

private struct ModelRow: View {
    @ObservedObject var model: SettingsModel
    let id: String
    let title: String
    let spec: ModelSpec
    let deletable: Bool

    var body: some View {
        let installed = model.isInstalled(spec)
        let megabytes = Double(spec.files.reduce(Int64(0)) { $0 + $1.bytes }) / 1_048_576
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading) {
                    Text(title)
                    Text(String(format: "約 %.0f MB", megabytes) + "・" + (installed ? "取得済み" : "未取得")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch model.downloads[id] ?? .idle {
                case .downloading: ProgressView().controlSize(.small)
                default:
                    if !installed { Button("取得") { model.download(id: id, spec: spec) } }
                    else if deletable { Button("削除") { model.deleteSpeechModel(id: id, spec: spec) } }
                }
            }
            if case let .downloading(file, fraction) = model.downloads[id] ?? .idle {
                ProgressView(value: fraction) { Text(file).font(.caption) }
            }
            if case let .failed(message) = model.downloads[id] ?? .idle { Text(message).font(.caption).foregroundStyle(.red) }
        }
    }
}

// MARK: スキル

private struct SkillsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let loaded = model.loadedSkills()
        Section("スキル（声で頼めること）") {
            if loaded.skills.isEmpty { Text("スキルが、まだありません。ターミナルで vc skills install <名前> を実行するか、フォルダに置いてください。").foregroundStyle(.secondary) }
            ForEach(loaded.skills, id: \.name) { skill in
                Toggle(isOn: Binding(get: { model.settings.isEnabled(skill.name) }, set: { model.setSkill(skill.name, enabled: $0) })) {
                    VStack(alignment: .leading) {
                        Text(skill.name)
                        Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            ForEach(loaded.problems, id: \.location) { problem in
                Text("読めないスキル: \(problem.location)：\(problem.reason)").font(.caption).foregroundStyle(.red)
            }
            Button("スキルのフォルダを開く") { NSWorkspace.shared.open(VoiceControlHome.root.appendingPathComponent("skills")) }
        }
        Section {
            Text("有効・無効は、すぐに効きます（再起動は要りません）。スキルの取得・作成は、ターミナルの vc skills（コマンド vc は、メニューの「一般」から入れられます）。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: 一般

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    private func permissionRow(_ title: String, granted: Bool?, pane: String, note: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: granted == true ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(granted == true ? Color.green : Color.orange)
            Text(granted == true ? "許可済み" : (granted == nil ? "未確認" : "許可なし"))
            Button("開く") { AppActions.openPrivacy(pane) }
        }
    }

    var body: some View {
        let _ = model.revision
        Section("許可（許可は、このアプリ自身に付きます）") {
            permissionRow("マイク", granted: MicRecorder.permission == .granted ? true : (MicRecorder.permission == .notDetermined ? nil : false), pane: "Privacy_Microphone", note: "声の入力に必須")
            permissionRow("アクセシビリティ", granted: ModifierHold.isTrusted, pane: "Privacy_Accessibility", note: "キーの検出（修飾キーの長押し・Esc）と、前面のアプリへの入力に必要")
            permissionRow("画面収録", granted: ScreenCapture.isAllowed, pane: "Privacy_ScreenCapture", note: "画面撮影・画面を見るスキルを使うときだけ")
            Button("もう一度、確かめる") { model.reload() }
        }
        Section("アプリ") {
            Toggle("ログイン時に起動", isOn: Binding(get: { AppActions.loginItemEnabled }, set: { _ in
                if let problem = AppActions.toggleLoginItem() { AppAlerts.show(title: "ログイン時の起動を変えられません", message: problem, style: .warning) }
                model.reload()
            }))
            CommandLineRow(model: model)
            Button("診断を見る（vc doctor）") { AppActions.showDoctor() }
            Button("設定ファイルを開く") { AppActions.openSettingsFile() }
            Button("データのフォルダを開く（スキル・設定・モデル）") { AppActions.openDataFolder() }
        }
        Section {
            Text("voice-control \(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CommandLineRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let tool = CommandLineTool()
        let installed = tool.state == .installed
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ターミナルのコマンド「vc」（/usr/local/bin）")
                Spacer()
                switch tool.state {
                case .unavailable: Text("アプリを「アプリケーション」へ移すと入れられます").font(.caption).foregroundStyle(.secondary)
                case let .other(path): Text("\(path) に、別のものがあります").font(.caption).foregroundStyle(.orange)
                case .installed, .notInstalled, .stale:
                    Button(installed ? "外す" : (tool.state == .notInstalled ? "インストール" : "付け替える")) {
                        if let problem = AppActions.toggleCommandLine() { AppAlerts.show(title: "コマンドを変えられません", message: problem, style: .warning) }
                        model.reload()
                    }
                }
            }
            Text("スキルが使うコマンド（vc show・vc image など）と、スキルの管理（vc skills）を、ターミナルから使えます。管理者のパスワードを求められることがあります。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

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

    func show(page: SettingsPage? = nil) {
        model.reload()
        if let page { model.page = page }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "voice-control の設定"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: 見た目の部品

/// 画面の上のパネル（HUD）と、アイコンに合わせた色。
enum Brand {
    static let rec1 = Color(red: 1.0, green: 0.30, blue: 0.28)
    static let rec2 = Color(red: 1.0, green: 0.62, blue: 0.20)
    static let think1 = Color(red: 0.40, green: 0.82, blue: 1.0)
    static let think2 = Color(red: 0.72, green: 0.42, blue: 0.98)
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.52)
    static let warn = Color(red: 1.0, green: 0.80, blue: 0.25)
    static let accent = LinearGradient(colors: [rec2, rec1], startPoint: .top, endPoint: .bottom)
}

extension SettingsPage {
    /// サイドバーの角丸の色（上から下へ、少し濃くなる）。
    var colors: [Color] {
        switch self {
        case .keys: return [Brand.rec2, Brand.rec1]
        case .voice: return [Brand.think1, Color(red: 0.25, green: 0.55, blue: 0.95)]
        case .models: return [Brand.think2, Color(red: 0.45, green: 0.30, blue: 0.90)]
        case .skills: return [Brand.ok, Color(red: 0.15, green: 0.65, blue: 0.45)]
        case .general: return [Color(white: 0.62), Color(white: 0.42)]
        }
    }

    var subtitle: String {
        switch self {
        case .keys: return "押している間だけ話す、キーを決めます"
        case .voice: return "録音・読み上げ・つなぎ言葉"
        case .models: return "スキルを動かすモデル・会話・音声認識"
        case .skills: return "声で頼めることの、有効・無効"
        case .general: return "許可・起動・コマンド・診断"
        }
    }
}

private struct Badge: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
            .shadow(color: colors.last?.opacity(0.35) ?? .clear, radius: 3, y: 1)
    }
}

/// 角丸のカード。題名（小さく）・中身・補足。
private struct Card<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 6) }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            if let footer { Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 14).opacity(0.7) }
}

/// 1 行：左に題名と説明、右に部品。
private struct Row<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.detail = detail; self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// キーの見た目（キーボードのキーのように）。
private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .frame(minWidth: 34, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))
            .shadow(color: .black.opacity(0.18), radius: 0, y: 2)
    }
}

/// 状態の小さな札（許可済み・取得済み など）。
private struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// ブランドの色のスイッチ（ウィンドウが、アクティブでなくても、同じ色で描く）。
private struct BrandSwitch: View {
    let isOn: Binding<Bool>
    var tint: [Color] = [Brand.rec2, Brand.rec1]

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.16)) { isOn.wrappedValue.toggle() } } label: {
            ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                Capsule().fill(isOn.wrappedValue ? AnyShapeStyle(LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.primary.opacity(0.16)))
                Circle().fill(.white).frame(width: 20, height: 20).shadow(color: .black.opacity(0.28), radius: 1.5, y: 1).padding(2)
            }
            .frame(width: 40, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isOn.wrappedValue ? "オン" : "オフ"))
    }
}

private struct SwitchRow: View {
    @ObservedObject var model: SettingsModel
    let title: String
    let detail: String?
    let value: Bool
    let set: (inout VCCore.Settings, Bool) -> Void

    var body: some View {
        Row(title, detail: detail) {
            BrandSwitch(isOn: Binding(get: { value }, set: { newValue in model.update { set(&$0, newValue) } }))
        }
    }
}

// MARK: 全体

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let _ = model.revision
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 214)
            Divider()
            VStack(spacing: 0) {
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.1))
                }
                if model.needsRestart {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Brand.rec2)
                        Text("変えた設定を反映するには、再起動が要ります").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("今すぐ再起動") { AppActions.relaunch() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Brand.rec2.opacity(0.14))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PageHeader(page: model.page)
                        switch model.page {
                        case .keys: KeysPage(model: model)
                        case .voice: VoicePage(model: model)
                        case .models: ModelsPage(model: model)
                        case .skills: SkillsPage(model: model)
                        case .general: GeneralPage(model: model)
                        }
                    }
                    .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 820, height: 600)
        .ignoresSafeArea()
    }
}

private struct Sidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 38, height: 38) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("voice-control").font(.system(size: 14, weight: .semibold))
                    Text("バージョン \(AppInfo.version)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.top, 38).padding(.bottom, 18)
            VStack(spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    Button { model.page = page } label: {
                        HStack(spacing: 10) {
                            Badge(symbol: page.symbol, colors: page.colors)
                            Text(page.title).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(model.page == page ? Color.primary.opacity(0.10) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            Spacer()
            Text("音声・画面は、\nこの Mac の外へ出しません").font(.system(size: 10)).foregroundStyle(.tertiary).padding(16)
        }
        .frame(maxHeight: .infinity)
        .background(VisualEffect(material: .sidebar))
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

private struct PageHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 14) {
            Badge(symbol: page.symbol, colors: page.colors, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title).font(.system(size: 22, weight: .bold))
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: キー

private struct KeysPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Card("押している間だけ話す", footer: "修飾キーだけのキー（shift・ctrl・rcmd・ropt など）の長押しは、アクセシビリティの許可が要ります。書き方：shift・ctrl+opt+space・f5・rcmd（右の Command）など。") {
            ForEach(Array(KeyKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { RowDivider() }
                KeyRow(model: model, kind: kind)
            }
        }
        Card("操作") {
            SwitchRow(model: model, title: "手放し（ダブルタップ）", detail: "キーを短く 2 回押すと、黙るまで録音します（押し続ける使い方は、そのまま）", value: model.settings.handsFree ?? true) { $0.handsFree = $1 }
        }
    }
}

private struct KeyRow: View {
    @ObservedObject var model: SettingsModel
    let kind: KeyKind

    var body: some View {
        let draft = model.keyDrafts[kind] ?? ""
        let saved = model.settings[keyPath: kind.keyPath] ?? ""
        let shown: String = {
            let text = draft.trimmingCharacters(in: .whitespaces).isEmpty ? (kind == .listen ? "shift" : "") : draft
            if case let .success(spec) = HotKeySpec.parse(text) { return String(spec.displayName.split(whereSeparator: { "(（".contains($0) })[0]).trimmingCharacters(in: .whitespaces) }
            return text.isEmpty ? "—" : "?"
        }()
        VStack(alignment: .leading, spacing: 6) {
            Row(kind.title, detail: kind.help) {
                HStack(spacing: 8) {
                    KeyCap(text: shown)
                    TextField("", text: Binding(get: { draft }, set: { model.setDraft(kind, $0) }), prompt: Text(kind.isOptional ? "使わない" : "shift"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 118)
                        .onSubmit { model.commitKey(kind) }
                    Menu {
                        ForEach(kind.presets, id: \.self) { preset in Button(preset) { model.setDraft(kind, preset); model.commitKey(kind) } }
                        if kind.isOptional { Divider(); Button("使わない") { model.setDraft(kind, ""); model.commitKey(kind) } }
                    } label: { Image(systemName: "chevron.down.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    if draft != saved {
                        Button("適用") { model.commitKey(kind) }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small).disabled(model.keyProblems[kind] != nil)
                    }
                }
            }
            if let problem = model.keyProblems[kind] {
                Label(problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }
}

// MARK: 音声

private struct VoicePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Card("録音") {
            SwitchRow(model: model, title: "録音中は、ほかの音を消す", detail: "マイクが、再生中の音楽や通話を拾わないように", value: model.settings.mute ?? true) { $0.mute = $1 }
            RowDivider()
            SwitchRow(model: model, title: "録音中の文字を、画面の上に出す", detail: "聞こえている文字を、字幕のように（実験）", value: model.settings.liveCaption ?? true) { $0.liveCaption = $1 }
            RowDivider()
            SwitchRow(model: model, title: "聞き取りに自信がないとき、確かめる", detail: "実行の前に、聞こえた文を確かめます（実験）", value: model.settings.recheck ?? true) { $0.recheck = $1 }
        }
        Card("読み上げ", footer: "確認の問いかけは、いつも読み上げます。より自然な声は、システム設定 > アクセシビリティ > 読み上げコンテンツ で入れられます。") {
            SwitchRow(model: model, title: "実行の結果を、声で読み上げる", detail: nil, value: model.settings.speakResults ?? false) { $0.speakResults = $1 }
            RowDivider()
            Row("声", detail: "自動：入っている日本語の声のうち、品質が最も高いもの") {
                HStack {
                    Picker("", selection: Binding(get: { model.settings.voice ?? "" }, set: { value in model.update { $0.voice = value.isEmpty ? nil : value } })) {
                        Text("自動").tag("")
                        ForEach(SpeechVoice.installed().sorted { ($0.quality, $1.identifier) > ($1.quality, $0.identifier) }, id: \.identifier) { Text($0.name).tag($0.identifier) }
                    }
                    .labelsHidden().frame(width: 150)
                    Button { say("声の確認です。こんにちは。") } label: { Image(systemName: "speaker.wave.2.fill") }.help("試しに読む")
                }
            }
        }
        Card("音声入力のつなぎ言葉", footer: "消す言葉は、1 行に 1 つ。空にすると、既定の辞書を使います。声で頼む内容には、使いません。") {
            SwitchRow(model: model, title: "つなぎ言葉（えーと・um など）を消す", detail: nil, value: model.settings.removeFillers ?? false) { $0.removeFillers = $1 }
            RowDivider()
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $model.fillersText)
                    .font(.system(size: 12)).frame(height: 84).scrollContentBackground(.hidden)
                    .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                HStack {
                    Button("保存") { model.saveFillers() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small)
                    Button("既定に戻す") { model.resetFillers() }.controlSize(.small)
                }
            }
            .padding(14)
        }
    }
}

// MARK: モデル

private struct ModelsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Card("スキルを実行するモデル", footer: "この Mac のサーバー（127.0.0.1）だけ使えます。クラウドのモデルは、使えません。") {
            Row("エンジン", detail: nil) {
                Picker("", selection: Binding(get: { model.engineKind }, set: { model.setEngine(kind: $0, rest: $0 == .apple ? "" : model.engineRest) })) {
                    Text("Apple").tag(SettingsRules.EngineKind.apple)
                    Text("Ollama").tag(SettingsRules.EngineKind.ollama)
                    Text("OpenAI 互換").tag(SettingsRules.EngineKind.openai)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 270)
            }
            if model.engineKind != .apple {
                RowDivider()
                Row("モデル", detail: model.engineKind == .ollama ? "例：qwen3.5:4b" : "例：モデル名@ポート") {
                    TextField("", text: Binding(get: { model.engineRest }, set: { model.setEngine(kind: model.engineKind, rest: $0) }), prompt: Text(model.engineKind.placeholder))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
                }
                if let problem = model.engineProblem {
                    Label(problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
                }
            }
            RowDivider()
            SwitchRow(model: model, title: "複数のステップに分けて実行", detail: "1 つの依頼を、順に実行できるか、言語モデルが決めます（実験）", value: model.settings.multiStep ?? true) { $0.multiStep = $1 }
        }
        Card("会話") {
            Row("会話に使うエージェント", detail: nil) {
                Picker("", selection: Binding(get: { model.settings.chatAgent ?? "apple" }, set: { value in model.update { $0.chatAgent = value == "apple" ? nil : value } })) {
                    ForEach(ChatAgent.allCases, id: \.rawValue) { Text($0.rawValue == "apple" ? "Apple（この Mac の中）" : $0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 190)
            }
            if let name = model.settings.chatAgent, ChatAgent.parse(name)?.isExternal == true {
                Label("会話の発話が、この Mac の外（そのエージェントの提供元）へ送られます。画像・コピーした文章は、渡しません。", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
            }
        }
        Card("音声認識") {
            Row("使う音声認識", detail: "Whisper は、下で取得してから選べます") {
                Picker("", selection: Binding(get: { model.settings.stt ?? "apple" }, set: { model.setSTT($0) })) {
                    ForEach(model.sttChoices, id: \.id) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().frame(width: 250)
            }
        }
        Card("モデルの取得", footer: "取得だけが、外部との通信です。音声・画面は、送りません。取得したファイルは、SHA-256 で検証します（途中から再開できます）。") {
            ModelRow(model: model, id: TinyJevModel.spec.name, title: "Tiny-Jev 0.6B", detail: "スキルを選ぶモデル（必須）", spec: TinyJevModel.spec, deletable: false)
            ForEach(SpeechModelCatalog.all, id: \.id) { entry in
                RowDivider()
                ModelRow(model: model, id: entry.id, title: entry.name, detail: "音声認識（任意）", spec: entry.spec, deletable: true)
            }
        }
    }
}

private struct ModelRow: View {
    @ObservedObject var model: SettingsModel
    let id: String
    let title: String
    let detail: String
    let spec: ModelSpec
    let deletable: Bool

    var body: some View {
        let installed = model.isInstalled(spec)
        let megabytes = Double(spec.files.reduce(Int64(0)) { $0 + $1.bytes }) / 1_048_576
        let state = model.downloads[id] ?? .idle
        VStack(alignment: .leading, spacing: 6) {
            Row(title, detail: detail + String(format: "・約 %.0f MB", megabytes)) {
                HStack(spacing: 10) {
                    Pill(text: installed ? "取得済み" : "未取得", color: installed ? Brand.ok : Color.secondary)
                    switch state {
                    case .downloading: ProgressView().controlSize(.small)
                    default:
                        if !installed { Button("取得") { model.download(id: id, spec: spec) }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small) }
                        else if deletable { Button("削除") { model.deleteSpeechModel(id: id, spec: spec) }.controlSize(.small) }
                    }
                }
            }
            if case let .downloading(file, fraction) = state {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: fraction).tint(Brand.rec2)
                    Text("\(file)　\(Int(fraction * 100))%").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
            if case let .failed(message) = state {
                Label(message, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }
}

// MARK: スキル

private struct SkillsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let loaded = model.loadedSkills()
        Card("スキル", footer: "有効・無効は、すぐに効きます（再起動は要りません）。スキルの取得・作成は、ターミナルの vc skills（コマンド vc は、「一般」から入れられます）。") {
            if loaded.skills.isEmpty {
                Row("スキルが、まだありません", detail: "ターミナルで vc skills install --all を実行するか、フォルダに置いてください") { EmptyView() }
            }
            ForEach(Array(loaded.skills.enumerated()), id: \.element.name) { index, skill in
                if index > 0 { RowDivider() }
                Row(skill.name, detail: skill.description) {
                    BrandSwitch(isOn: Binding(get: { model.settings.isEnabled(skill.name) }, set: { model.setSkill(skill.name, enabled: $0) }), tint: [Brand.ok, Color(red: 0.15, green: 0.65, blue: 0.45)])
                }
            }
            ForEach(loaded.problems, id: \.location) { problem in
                RowDivider()
                Label("読めないスキル: \(problem.location)：\(problem.reason)", systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(14)
            }
        }
        Button { NSWorkspace.shared.open(VoiceControlHome.root.appendingPathComponent("skills")) } label: { Label("スキルのフォルダを開く", systemImage: "folder") }.controlSize(.small)
    }
}

// MARK: 一般

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    private func permission(_ title: String, _ detail: String, granted: Bool?, pane: String) -> some View {
        Row(title, detail: detail) {
            HStack(spacing: 10) {
                Pill(text: granted == true ? "許可済み" : (granted == nil ? "未確認" : "許可なし"), color: granted == true ? Brand.ok : Brand.warn)
                Button("開く") { AppActions.openPrivacy(pane) }.controlSize(.small)
            }
        }
    }

    var body: some View {
        let _ = model.revision
        let mic = MicRecorder.permission
        Card("許可", footer: "許可は、このアプリ自身に付きます（ターミナルには、よりません）。変えたら、「もう一度、確かめる」。") {
            permission("マイク", "声の入力に必須", granted: mic == .granted ? true : (mic == .notDetermined ? nil : false), pane: "Privacy_Microphone")
            RowDivider()
            permission("アクセシビリティ", "キーの検出（修飾キーの長押し・Esc）と、前面のアプリへの入力", granted: ModifierHold.isTrusted, pane: "Privacy_Accessibility")
            RowDivider()
            permission("画面収録", "画面撮影・画面を見るスキルを使うときだけ", granted: ScreenCapture.isAllowed, pane: "Privacy_ScreenCapture")
            RowDivider()
            Row("状態を読み直す") { Button("もう一度、確かめる") { model.reload() }.controlSize(.small) }
        }
        Card("アプリ") {
            Row("ログイン時に起動") {
                BrandSwitch(isOn: Binding(get: { AppActions.loginItemEnabled }, set: { _ in
                    if let problem = AppActions.toggleLoginItem() { AppAlerts.show(title: "ログイン時の起動を変えられません", message: problem, style: .warning) }
                    model.reload()
                }))
            }
            RowDivider()
            CommandLineRow(model: model)
            RowDivider()
            Row("診断", detail: "必要なものが、そろっているかを確かめます（vc doctor）") { Button("見る") { AppActions.showDoctor() }.controlSize(.small) }
            RowDivider()
            Row("設定ファイル", detail: "~/.voice-control/settings.json") { Button("開く") { AppActions.openSettingsFile() }.controlSize(.small) }
            RowDivider()
            Row("データのフォルダ", detail: "スキル・設定・モデル") { Button("開く") { AppActions.openDataFolder() }.controlSize(.small) }
        }
    }
}

private struct CommandLineRow: View {
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
                    if installed { Pill(text: "インストール済み", color: Brand.ok) }
                    Button(installed ? "外す" : (tool.state == .notInstalled ? "インストール" : "付け替える")) {
                        if let problem = AppActions.toggleCommandLine() { AppAlerts.show(title: "コマンドを変えられません", message: problem, style: .warning) }
                        model.reload()
                    }.controlSize(.small)
                }
            }
        }
    }
}

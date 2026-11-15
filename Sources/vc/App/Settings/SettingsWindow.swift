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
        if window == nil { window = Self.makeWindow(model: model) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// ウィンドウの作り（アプリと、`vc settings-preview` が、同じものを使う：描いた絵が、実際の見た目になる）。内容の大きさは、タイトルバーの下まで、ぴったり。
    static func makeWindow(model: SettingsModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: settingsWidth, height: settingsHeight), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.title = "voice-control の設定"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

let settingsWidth: CGFloat = 820
let settingsHeight: CGFloat = 640

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
        case .general: return "準備状況・起動・コマンド・診断"
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

/// 説明の帯（使い方の例など）。
private struct Callout: View {
    let symbol: String
    let text: String
    var tint: Color = Brand.think1

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint).frame(width: 18)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
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
        .frame(minWidth: settingsWidth, maxWidth: .infinity, minHeight: settingsHeight, maxHeight: .infinity)
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
        Callout(symbol: "hand.tap.fill", text: "キーを押している間だけ、話します。たとえば、Shift を押したまま「電卓を開いて」と言って、離すと、実行されます。キーの欄を押して、使いたいキーを押すと、決まります。")
        Card("押している間だけ話す", footer: "修飾キーだけのキー（⇧ ⌃ ⌥ ⌘）の長押しは、アクセシビリティの許可が要ります。右側のキーだけにすると、普段の入力での誤作動が減ります。") {
            ForEach(Array(KeyKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { RowDivider() }
                KeyRow(model: model, kind: kind)
            }
        }
        Card("操作") {
            SwitchRow(model: model, title: "手放し（ダブルタップ）", detail: "キーを短く 2 回押すと、黙るまで録音します（押し続ける使い方も、そのまま使えます）", value: model.settings.handsFree ?? true) { $0.handsFree = $1 }
        }
    }
}

private struct KeyRow: View {
    @ObservedObject var model: SettingsModel
    let kind: KeyKind

    var body: some View {
        let saved = model.settings[keyPath: kind.keyPath] ?? ""
        let isRecording = model.recording == kind
        let effective = saved.isEmpty ? (kind == .listen ? "shift" : "") : saved
        let label: String = {
            if case let .success(spec) = HotKeySpec.parse(effective) { return KeyRow.label(of: spec) }
            return effective.isEmpty ? "未設定" : "?"
        }()
        VStack(alignment: .leading, spacing: 6) {
            Row(kind.title, detail: kind.help) {
                HStack(spacing: 8) {
                    Button { isRecording ? model.stopRecording() : model.startRecording(kind) } label: {
                        Text(isRecording ? "キーを押してください…" : label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(isRecording ? Brand.rec1 : (effective.isEmpty ? Color.secondary : Color.primary))
                            .padding(.horizontal, 12).frame(minWidth: 86, minHeight: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isRecording ? Brand.rec2.opacity(0.14) : Color(nsColor: .windowBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isRecording ? Brand.rec1 : Color.primary.opacity(0.18), lineWidth: isRecording ? 1.5 : 1))
                            .shadow(color: .black.opacity(isRecording ? 0 : 0.16), radius: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("押して、使いたいキーを押す（Esc で取りやめ）")
                    Menu {
                        ForEach(kind.presets, id: \.self) { preset in
                            Button(KeyRow.title(of: preset)) { model.setDraft(kind, preset); model.commitKey(kind) }
                        }
                        if kind.isOptional { Divider(); Button("使わない") { model.setDraft(kind, ""); model.commitKey(kind) } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("候補から選ぶ")
                }
            }
            if isRecording {
                Label(model.recordingHint ?? "修飾キーだけなら、押して、離します。組み合わせなら、続けて押します。", systemImage: model.recordingHint == nil ? "keyboard" : "exclamationmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(model.recordingHint == nil ? Color.secondary : Brand.rec1)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            } else if let problem = model.keyProblems[kind] {
                Label(problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }

    /// キーの表示：記号と、書き方（例：「⇧  shift」「右⌘  rcmd」「⌃⌥S  ctrl+opt+s」）。
    static func label(of spec: HotKeySpec) -> String {
        let symbols = String(spec.displayName.split(whereSeparator: { "(（".contains($0) })[0]).trimmingCharacters(in: .whitespaces)
        return "\(symbols)  \(spec.description)"
    }

    /// 候補メニューの表示。
    static func title(of preset: String) -> String {
        if case let .success(spec) = HotKeySpec.parse(preset) { return label(of: spec) }
        return preset
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
                    Pill(text: pending == 0 ? "OK" : "要設定", color: pending == 0 ? Brand.ok : Brand.warn)
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
                    Pill(text: ScreenCapture.isAllowed ? "許可済み" : "許可なし", color: ScreenCapture.isAllowed ? Brand.ok : Color.secondary)
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

private struct LoginRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let state = AppActions.loginItemState
        let message = model.loginMessage
        VStack(alignment: .leading, spacing: 6) {
            Row("ログイン時に起動", detail: state == .unavailable ? "このアプリの場所では、登録できません。「アプリケーション」フォルダへ移してください" : nil) {
                HStack(spacing: 10) {
                    if state == .needsApproval { Pill(text: "承認が必要", color: Brand.warn) }
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

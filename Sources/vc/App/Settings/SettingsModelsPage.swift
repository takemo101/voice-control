import AppKit
import SwiftUI
import VCCore
import VCDecision
import VCSkill
import VCSpeech

// MARK: モデル

struct ModelsPage: View {
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
            let agent = ChatAgent.parse(model.settings.chatAgent ?? "apple") ?? .apple
            if agent.isExternal {
                Label("会話の発話が、この Mac の外（そのエージェントの提供元）へ送られます。画像・コピーした文章は、渡しません。", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
            }
            RowDivider()
            Row("道具", detail: agent.isExternal ? model.chatToolLevel.title : (model.chatToolLevel == .none ? "なし（会話だけ）" : (model.chatToolLevel == .web ? "Web 検索・日時" : (model.chatToolLevel == .read ? "＋ ファイルを読む（作業フォルダ）" : "すべて（書き込み・コマンド。確認つき）")))) {
                Picker("", selection: Binding(get: { agent.effective(model.chatToolLevel) }, set: { model.setChatTools($0) })) {
                    Text("なし").tag(ChatToolLevel.none)
                    if agent.canSearchWeb { Text("Web").tag(ChatToolLevel.web) }
                    Text("＋読む").tag(ChatToolLevel.read)
                    Text("すべて").tag(ChatToolLevel.all)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 250)
            }
            if !agent.isExternal, model.chatToolLevel == .all {
            Label("作業フォルダの中への書き込みと、コマンドの実行ができます。既存ファイルの上書きと、安全でないコマンドは、毎回、確認します。シェル・インタプリタ・通信のコマンドは、実行できません。", systemImage: "exclamationmark.octagon.fill")
                .font(.system(size: 11)).foregroundStyle(Brand.rec1).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
        }
        if !agent.isExternal, model.chatToolLevel != .none {
            Label("Web 検索の検索語と、開いたページの URL が、この Mac の外へ送られます（発話そのもの・画面・ファイルの中身は、送りません）。道具を開けている間は、画像・コピーした文章は、渡しません。", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
        }
        if agent.isExternal, model.chatToolLevel == .all {
                Label("ファイルの書き込み・コマンドの実行まで、確認なしで、できます。聞き間違いや、Web のページの命令で、意図しない操作が起きえます。実行した操作は、答えの下に出ます。", systemImage: "exclamationmark.octagon.fill")
                    .font(.system(size: 11)).foregroundStyle(Brand.rec1).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
            }
            if model.chatToolLevel.usesFolder {
                RowDivider()
                Row("作業フォルダ", detail: model.chatFolderPath) {
                    HStack(spacing: 8) {
                        Button("選ぶ…") { model.chooseChatFolder() }.controlSize(.small)
                        Button("開く") {
                            try? FileManager.default.createDirectory(atPath: model.chatFolderPath, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(URL(fileURLWithPath: model.chatFolderPath))
                        }.controlSize(.small)
                    }
                }
            }
            RowDivider()
            Row("会話の記録", detail: "メモリだけ（保存しません）。5 分間話さないと、自動で終わります。声で「会話を終わって」でも消せます") {
                Button("リセット") { AppActions.resetConversation() }.controlSize(.small)
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

struct ModelRow: View {
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
                    SettingsPill(text: installed ? "取得済み" : "未取得", color: installed ? Brand.ok : Color.secondary)
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

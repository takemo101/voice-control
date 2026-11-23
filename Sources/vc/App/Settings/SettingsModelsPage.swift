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
        Card(tr("スキルを実行するモデル"), footer: tr("この Mac と、同じ LAN のサーバーだけ使えます。インターネットのクラウドのモデルは、使えません。")) {
            Row(tr("エンジン"), detail: nil) {
                Picker("", selection: Binding(get: { model.engineKind }, set: { model.switchEngineKind($0) })) {
                    Text("Apple").tag(SettingsRules.EngineKind.apple)
                    Text("Ollama").tag(SettingsRules.EngineKind.ollama)
                    Text(tr("OpenAI 互換")).tag(SettingsRules.EngineKind.openai)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            if model.engineKind != .apple {
                RowDivider()
                Row(tr("モデル"), detail: model.engineKind == .ollama ? tr("例：qwen3.5:4b") : tr("サーバーが返すモデルの名前（例：qwen3-4b）")) {
                    HStack(spacing: 6) {
                        TextField("", text: Binding(get: { SettingsRules.splitOpenAI(model.engineRest).model }, set: { model.setModelEndpoint(model: $0) }), prompt: Text(model.engineKind.placeholder))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 180)
                        if model.engineModels.isEmpty {
                            Button(tr("一覧")) { model.loadEngineModels() }.controlSize(.small).disabled(model.engineServer == nil || model.engineProbe == .working)
                        } else {
                            Menu(tr("選ぶ")) { ForEach(model.engineModels, id: \.self) { name in Button(name) { model.chooseEngineModel(name) } } }.controlSize(.small).fixedSize()
                        }
                    }
                }
                RowDivider()
                Row(tr("エンドポイント"), detail: model.engineKind == .ollama ? tr("省くと 127.0.0.1:11434。LAN は http://192.168.1.5:11434。経路を替えるなら 末尾に /ollama など") : tr("この Mac は 8000。LAN は http://192.168.1.5:8080/v1。/v2 など、API の経路も書けます（省くと /v1）")) {
                    TextField("", text: Binding(get: { model.engineEndpointDraft }, set: { model.setModelEndpoint(endpoint: $0) }), prompt: Text(model.engineKind == .ollama ? "127.0.0.1:11434" : "127.0.0.1:8000"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
                }
                if let problem = model.engineProblem {
                    Label(problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
                }
                if let server = model.engineServer {
                    RowDivider()
                    Row(tr("APIキー"), detail: model.engineKeyConfigured ? tr("設定済み（表示しません）") : tr("なし。サーバーが要求するときだけ入れます")) {
                        HStack(spacing: 6) {
                            SecureField("", text: $model.engineKeyDraft, prompt: Text(model.engineKeyConfigured ? "••••••••" : "sk-…")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 150)
                            Button(tr("保存")) { model.setEngineKey(model.engineKeyDraft) }.controlSize(.small).disabled(model.engineKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            if model.engineKeyConfigured { Button(tr("消す")) { model.setEngineKey("") }.controlSize(.small) }
                        }
                    }
                    if let problem = model.engineKeyProblem {
                        Label(problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
                    }
                    RowDivider()
                    Row(tr("接続"), detail: tr("サーバー・APIキー・モデルがあるかを確かめます（質問は、送りません）")) {
                        Button(model.engineProbe == .working ? tr("確認中…") : tr("確かめる")) { model.checkEngine() }.controlSize(.small).disabled(model.engineProbe == .working || model.engineProblem != nil)
                    }
                    switch model.engineProbe {
                    case let .ok(text): Label(text, systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green).padding(.horizontal, 14).padding(.bottom, 8)
                    case let .failed(text): Label(text, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
                    default: EmptyView()
                    }
                    if !server.isLoopback {
                        RowDivider()
                        Row(tr("この LAN のサーバーを許可"), detail: tr("\(server.endpoint) へ、音声・画面の内容が、暗号化されずに送られます")) {
                            BrandSwitch(isOn: Binding(get: { model.engineLANApproved }, set: { model.setEngineLANApproved($0) }))
                        }
                        if !model.engineLANApproved {
                            Label(tr("許可するまで、この設定は、保存されず、使われません（いまは Apple のモデルです）。"), systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.bottom, 8)
                        }
                    }
                }
            }
            RowDivider()
            SwitchRow(model: model, title: tr("複数のステップに分けて実行"), detail: tr("1 つの依頼を、順に実行できるか、言語モデルが決めます（実験）"), value: model.settings.multiStep ?? true) { $0.multiStep = $1 }
        }
        Card(tr("音声認識")) {
            Row(tr("使う音声認識"), detail: tr("Whisper は、下で取得してから選べます")) {
                Picker("", selection: Binding(get: { model.settings.stt ?? "apple" }, set: { model.setSTT($0) })) {
                    ForEach(model.sttChoices, id: \.id) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().frame(width: 250)
            }
        }
        Card(tr("モデルの取得"), footer: tr("取得だけが、外部との通信です。音声・画面は、送りません。取得したファイルは、SHA-256 で検証します（途中から再開できます）。")) {
            ModelRow(model: model, id: TinyJevModel.spec.name, title: "Tiny-Jev 0.6B", detail: tr("スキルを選ぶモデル（必須）"), spec: TinyJevModel.spec, deletable: false)
            ForEach(SpeechModelCatalog.all, id: \.id) { entry in
                RowDivider()
                ModelRow(model: model, id: entry.id, title: entry.name, detail: tr("音声認識（任意）"), spec: entry.spec, deletable: true)
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
            Row(title, detail: detail + String(format: tr("・約 %.0f MB"), megabytes)) {
                HStack(spacing: 10) {
                    SettingsPill(text: installed ? tr("取得済み") : tr("未取得"), color: installed ? Brand.ok : Color.secondary)
                    switch state {
                    case .downloading: ProgressView().controlSize(.small)
                    default:
                        if !installed { Button(tr("取得")) { model.download(id: id, spec: spec) }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small) }
                        else if deletable { Button(tr("削除")) { model.deleteSpeechModel(id: id, spec: spec) }.controlSize(.small) }
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

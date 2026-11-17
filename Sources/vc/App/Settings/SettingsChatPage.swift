import AppKit
import SwiftUI
import VCCore
import VCSkill

// MARK: 会話

struct ChatPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Callout(symbol: "bubble.left.and.bubble.right.fill", text: "会話のキーを押している間だけ話すか、会話のウィンドウ（メニューバー > 会話を開く）で、文字で質問できます。ウィンドウの「画面を撮る」で、画像について話すこともできます。")
        Card("エージェントと道具", footer: "画像：Apple のモデルは、この Mac の中で文字にして読みます。外のエージェントへは、送るたびに、画像と送り先を確認します。") {
            // 選べるのは、この Mac に入っているエージェントだけ。選んだものが、なくなっていたら（アンインストールなど）、見つからない印つきで残し、Apple のモデルで答える
            let installed = AgentLocator.available()
            let selected = ChatAgent.parse(model.settings.chatAgent ?? "apple") ?? .apple
            let missing = selected.isExternal && !installed.contains(selected)
            Row("会話に使うエージェント", detail: installed.count == 1 ? "claude・codex などが、この Mac に入っていれば、ここに出ます" : nil) {
                Picker("", selection: Binding(get: { model.settings.chatAgent ?? "apple" }, set: { value in model.update { $0.chatAgent = value == "apple" ? nil : value } })) {
                    ForEach(installed + (missing ? [selected] : []), id: \.rawValue) { choice in
                        Text(choice == .apple ? "Apple（この Mac の中）" : (choice == selected && missing ? "\(choice.rawValue)（見つかりません）" : choice.rawValue)).tag(choice.rawValue)
                    }
                }
                .labelsHidden().frame(width: 190)
            }
            if missing {
                Label("\(selected.rawValue) が、この Mac に見つかりません（アンインストールされた？）。いまは、Apple のモデルで答えます。入れ直すと、また使えます。", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
            }
            let agent: ChatAgent = missing ? .apple : selected   // 道具の選択肢などは、実際に使うエージェントで決める
            if agent.speaksACP {
                RowDivider()
                SwitchRow(model: model, title: "常駐の接続（ACP）で話す", detail: "質問ごとに起動しないので、速くなります。書き込み・コマンドは、毎回、確認します。使えないときは、自動で、従来の方式に戻ります", value: model.settings.chatAcp ?? true) { $0.chatAcp = $1 }
                RowDivider()
                SwitchRow(model: model, title: "OS の制限つきで動かす（サンドボックス）", detail: "書き込みを、作業フォルダ（「すべて」のとき）とエージェント自身の置き場だけに限り、鍵の置き場（~/.ssh など）は読めなくします。確認で「はい」と答えても、外へは書けません。コマンドは、この制限の中で動くので、キャッシュの書き込み（npm install など）はできません", value: model.settings.chatSandbox ?? true) { $0.chatSandbox = $1 }
            }
            if agent.speaksACP, model.settings.chatAcp ?? true {
                RowDivider()
                ChatModelRow(model: model, agent: agent)
            }
            if agent.isExternal {
                Label("会話の発話が、この Mac の外（そのエージェントの提供元）へ送られます。画像は、送るたびに確認します。コピーした文章は、渡しません。", systemImage: "exclamationmark.triangle.fill")
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
            Label("Web 検索の検索語と、開いたページの URL が、この Mac の外へ送られます（発話そのもの・画面・ファイルの中身は、送りません）。画像・コピーした文章を使う会話では、Web 検索は、使いません。", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
        }
        if agent.isExternal, model.chatToolLevel == .all {
                // ACP で話すエージェントは、操作の前に、聞いてくる（毎回、確認する）。それ以外は、確認なし
                let confirms = agent.speaksACP && (model.settings.chatAcp ?? true)
                Label(confirms ? "ファイルの書き込み・コマンドの実行は、毎回、確認します（常駐の接続）。聞き間違いや、Web のページの命令で、意図しない操作を頼むことがあるので、確認の内容を、よく読んでください。"
                               : "ファイルの書き込み・コマンドの実行まで、確認なしで、できます。聞き間違いや、Web のページの命令で、意図しない操作が起きえます。実行した操作は、答えの下に出ます。", systemImage: "exclamationmark.octagon.fill")
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
    }
}

/// 検索の状態（ポップオーバーの開閉と、入力）。SwiftUI の `@State` は、この環境では使えないので、参照型。
@MainActor final class ModelSearchState: ObservableObject {
    @Published var isOpen = false
    @Published var query = ""
}

/// 会話のモデル：エージェントが返す一覧から選ぶ（ACP）。ボタンを押すと、**検索つきの一覧**が開く（あいまい検索：「son 5」→ Sonnet 5.5）。一覧は、初めて開くときに、そのエージェントを一時的に起動して取る（質問は送らない）。
struct ChatModelRow: View {
    @ObservedObject var model: SettingsModel
    let agent: ChatAgent
    @StateObject private var search = ModelSearchState()

    var body: some View {
        let state = model.modelLists[agent.rawValue]
        let chosen = model.chatModel(for: agent) ?? ""
        let listing: ACPModelListing? = { if case let .loaded(value) = state { return value }; return nil }()
        let isLoading = state == .loading
        let shownName = listing?.choices.first(where: { $0.id == chosen })?.name ?? chosen
        VStack(alignment: .leading, spacing: 6) {
            Row("モデル", detail: chosen.isEmpty ? "エージェントの設定のまま" : chosen) {
                HStack(spacing: 8) {
                    if isLoading { ProgressView().controlSize(.small) }
                    Button {
                        search.query = ""
                        search.isOpen = true
                        if listing == nil, !isLoading { model.loadModels(for: agent) }   // 初めて開くとき：一覧を取る（利用者が押したときだけ）
                    } label: {
                        HStack(spacing: 6) {
                            Text(chosen.isEmpty ? "エージェントの設定" : shownName).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .frame(width: 176, alignment: .leading)
                    }
                    .controlSize(.regular)
                    .help("押すと、検索つきの一覧が開きます（初めてのときは、\(agent.rawValue) を一時的に起動して、一覧を聞きます。質問は、送りません）")
                    .popover(isPresented: Binding(get: { search.isOpen }, set: { search.isOpen = $0 }), arrowEdge: .bottom) {
                        ModelSearchList(search: search, state: state, chosen: chosen, agentName: agent.rawValue,
                                        select: { id in model.setChatModel(id, for: agent); search.isOpen = false },
                                        reload: { model.loadModels(for: agent) })
                    }
                    if listing != nil { Button("取り直す") { model.loadModels(for: agent) }.controlSize(.small).disabled(isLoading) }
                }
            }
            if case let .failed(why) = state {
                Label("一覧を取れませんでした：\(why)", systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Brand.warn)
                    .padding(.horizontal, 14).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 検索つきの、モデルの一覧（ポップオーバーの中身）。入力で、あいまいに絞り込む（`FuzzyMatch`）。Return で、いちばん上を選ぶ。
struct ModelSearchList: View {
    @ObservedObject var search: ModelSearchState
    let state: SettingsModel.ModelListState?
    let chosen: String
    let agentName: String
    let select: (String?) -> Void
    let reload: () -> Void

    var body: some View {
        let choices: [ACPModelChoice] = { if case let .loaded(value) = state { return value.choices }; return [] }()
        let matches = FuzzyMatch.filter(choices, query: search.query) { "\($0.id) \($0.name)" }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("検索（例：son 5・haiku・gpt high）", text: $search.query)
                    .textFieldStyle(.plain)
                    .onSubmit { if let first = matches.first { select(first.id) } }
                if !search.query.isEmpty {
                    Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            switch state {
            case .none, .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(agentName) に、選べるモデルを聞いています…").font(.system(size: 12)).foregroundStyle(.secondary) }.padding(14)
            case let .failed(why):
                VStack(alignment: .leading, spacing: 8) {
                    Text("一覧を取れませんでした").font(.system(size: 12, weight: .semibold))
                    Text(why).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("もう一度") { reload() }.controlSize(.small)
                }.padding(14)
            case .loaded:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if search.query.isEmpty { row(title: "エージェントの設定（既定）", id: "", detail: nil) }
                        ForEach(matches) { choice in row(title: choice.name, id: choice.id, detail: choice.detail) }
                        if matches.isEmpty { Text("「\(search.query)」に合うモデルは、ありません").font(.system(size: 12)).foregroundStyle(.secondary).padding(14) }
                    }
                }
                .frame(maxHeight: 320)
                Divider()
                Text(search.query.isEmpty ? "\(choices.count) 件" : "\(matches.count) 件／全 \(choices.count) 件").font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .frame(width: 340)
    }

    private func row(title: String, id: String, detail: String?) -> some View {
        Button { select(id.isEmpty ? nil : id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(chosen == id ? 1 : 0).frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5)).lineLimit(1)
                    if !id.isEmpty, id != title { Text(id).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                    if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

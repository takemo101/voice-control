import AppKit
import SwiftUI
import VCCore
import VCSkill

// MARK: 会話

struct ChatPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Callout(symbol: "bubble.left.and.bubble.right.fill", text: tr("会話のキーを押している間話すか、メニューバー > 会話を開く、で、文字で質問できます。"))
        Card(tr("エージェントと道具"), footer: tr("画像は、外のエージェントへ送るたびに、確認します。")) {
            // 選べるのは、この Mac に入っているエージェントだけ。選んだものが、なくなっていたら（アンインストールなど）、見つからない印つきで残し、Apple のモデルで答える
            let installed = AgentLocator.available()
            let selected = ChatAgent.parse(model.settings.chatAgent ?? "apple") ?? .apple
            let missing = selected.isExternal && !installed.contains(selected)
            Row(tr("会話に使うエージェント"), detail: installed.count == 1 ? tr("claude・codex などが、この Mac に入っていれば、ここに出ます") : nil) {
                Picker("", selection: Binding(get: { model.settings.chatAgent ?? "apple" }, set: { value in model.update { $0.chatAgent = value == "apple" ? nil : value } })) {
                    ForEach(installed + (missing ? [selected] : []), id: \.rawValue) { choice in
                        Text(choice == .apple ? tr("Apple（この Mac の中）") : (choice == selected && missing ? tr("\(choice.rawValue)（見つかりません）") : choice.rawValue)).tag(choice.rawValue)
                    }
                }
                .labelsHidden().frame(width: 190)
            }
            if missing {
                Label(tr("\(selected.rawValue) が、この Mac に見つかりません（アンインストールされた？）。いまは、Apple のモデルで答えます。入れ直すと、また使えます。"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
            }
            let agent: ChatAgent = missing ? .apple : selected   // 道具の選択肢などは、実際に使うエージェントで決める
            if let adapter = ACPAdapter.of(agent) {
                RowDivider()
                AdapterRow(model: model, adapter: adapter)
            }
            if agent.speaksACP {
                RowDivider()
                SwitchRow(model: model, title: tr("常駐の接続（ACP）で話す"), detail: tr("速く答えます。使えないときは、従来の方式に戻ります"), value: model.settings.chatAcp ?? true) { $0.chatAcp = $1 }
                RowDivider()
                SwitchRow(model: model, title: tr("OS の制限つきで動かす（サンドボックス）"), detail: tr("書き込みを、作業フォルダだけに限ります"), value: model.settings.chatSandbox ?? true) { $0.chatSandbox = $1 }
            }
            if agent.talksACP(enabled: model.settings.chatAcp ?? true), ACPAdapter.of(agent).map({ AdapterStatus.of($0).isUsable }) ?? true {
                RowDivider()
                ChatModelRow(model: model, agent: agent)
            }
            if agent.isExternal {
                Label(tr("発話は、この Mac の外（提供元）へ送られます。"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
            }
            RowDivider()
            Row(tr("道具"), detail: agent.isExternal ? model.chatToolLevel.title : (model.chatToolLevel == .none ? tr("なし（会話だけ）") : (model.chatToolLevel == .web ? tr("Web 検索・日時") : (model.chatToolLevel == .read ? tr("＋ ファイルを読む（作業フォルダ）") : tr("すべて（書き込み・コマンド。確認つき）"))))) {
                Picker("", selection: Binding(get: { agent.effective(model.chatToolLevel) }, set: { model.setChatTools($0) })) {
                    Text(tr("なし")).tag(ChatToolLevel.none)
                    if agent.canSearchWeb { Text("Web").tag(ChatToolLevel.web) }
                    Text(tr("＋読む")).tag(ChatToolLevel.read)
                    Text(tr("すべて")).tag(ChatToolLevel.all)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            if !agent.isExternal, model.chatToolLevel == .all {
            Label(tr("書き込みとコマンドの実行ができます。上書きと安全でないコマンドは、毎回、確認します。"), systemImage: "exclamationmark.octagon.fill")
                .font(.system(size: 11)).foregroundStyle(Brand.rec1).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
        }
        if !agent.isExternal, model.chatToolLevel != .none {
            Label(tr("検索語と開いたページの URL が、この Mac の外へ送られます。"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
        }
        if agent.isExternal, model.chatToolLevel == .all {
                // ACP で話すエージェントは、操作の前に、聞いてくる（毎回、確認する）。それ以外は、確認なし。自動モードは、下の行が示す
                let confirms = agent.talksACP(enabled: model.settings.chatAcp ?? true)
                if !confirms || !((model.settings.chatAuto ?? false) && (model.settings.chatSandbox ?? true)) {
                    Label(confirms ? tr("書き込み・コマンドは、毎回、確認します。") : tr("確認なしで、書き込み・コマンドができます。意図しない操作が起きえます。"), systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 11)).foregroundStyle(Brand.rec1).padding(.horizontal, 14).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
                }
            }
            if agent.isExternal, agent.talksACP(enabled: model.settings.chatAcp ?? true), model.chatToolLevel == .all {
                RowDivider()
                let sandboxOn = model.settings.chatSandbox ?? true
                Row(tr("自動モード"), detail: sandboxOn ? tr("作業フォルダの中は、確認なしで実行します") : tr("「OS の制限つきで動かす」をオンにすると、使えます")) {
                    BrandSwitch(isOn: Binding(get: { (model.settings.chatAuto ?? false) && sandboxOn }, set: { model.setChatAuto($0) })).opacity(sandboxOn ? 1 : 0.4).disabled(!sandboxOn)
                }
            }
            if model.chatToolLevel.usesFolder {
                RowDivider()
                Row(tr("作業フォルダ"), detail: model.chatFolderPath) {
                    HStack(spacing: 8) {
                        Button(tr("選ぶ…")) { model.chooseChatFolder() }.controlSize(.small)
                        Button(tr("開く")) {
                            try? FileManager.default.createDirectory(atPath: model.chatFolderPath, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(URL(fileURLWithPath: model.chatFolderPath))
                        }.controlSize(.small)
                    }
                }
            }
            RowDivider()
            Row(tr("会話の記録"), detail: tr("メモリだけ。5 分話さないと、終わります")) {
                Button(tr("リセット")) { AppActions.resetConversation() }.controlSize(.small)
            }
        }
    }
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
            Row(tr("モデル"), detail: chosen.isEmpty ? tr("エージェントの設定のまま") : chosen) {
                HStack(spacing: 8) {
                    if isLoading { ProgressView().controlSize(.small) }
                    Button {
                        search.query = ""
                        search.isOpen = true
                        if listing == nil, !isLoading { model.loadModels(for: agent) }   // 初めて開くとき：一覧を取る（利用者が押したときだけ）
                    } label: {
                        HStack(spacing: 6) {
                            Text(chosen.isEmpty ? tr("エージェントの設定") : shownName).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .frame(width: 176, alignment: .leading)
                    }
                    .controlSize(.regular)
                    .help(tr("押すと、検索つきの一覧が開きます（初めてのときは、\(agent.rawValue) を一時的に起動して、一覧を聞きます。質問は、送りません）"))
                    .popover(isPresented: Binding(get: { search.isOpen }, set: { search.isOpen = $0 }), arrowEdge: .bottom) {
                        ModelSearchList(search: search, state: state, chosen: chosen, agentName: agent.rawValue,
                                        select: { id in model.setChatModel(id, for: agent); search.isOpen = false },
                                        reload: { model.loadModels(for: agent) })
                    }
                    if listing != nil { Button(tr("取り直す")) { model.loadModels(for: agent) }.controlSize(.small).disabled(isLoading) }
                }
            }
            if case let .failed(why) = state {
                Label(tr("一覧を取れませんでした：\(why)"), systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Brand.warn)
                    .padding(.horizontal, 14).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// ACP アダプターの行（`claude`・`codex`）：状態・入れる／更新／消す。**入れるのは、利用者が押して、確認したときだけ**。
struct AdapterRow: View {
    @ObservedObject var model: SettingsModel
    let adapter: ACPAdapter

    var body: some View {
        let _ = model.revision
        let status = AdapterStatus.of(adapter)
        let work = model.adapterWork[adapter.agent.rawValue]
        VStack(alignment: .leading, spacing: 6) {
            Row(tr("ACP アダプター"), detail: status.summary(for: adapter)) {
                HStack(spacing: 8) {
                    if case .working = work { ProgressView().controlSize(.small) }
                    switch status {
                    case .own:
                        SettingsPill(text: tr("使用中"), color: Brand.ok)
                    case let .managed(_, current):
                        if !current { Button(tr("\(adapter.version) に更新…")) { model.installAdapter(adapter) }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small).disabled(work != nil) }
                        else { SettingsPill(text: tr("導入済み"), color: Brand.ok) }
                        Button(tr("消す")) { model.removeAdapter(adapter) }.controlSize(.small).disabled(work != nil)
                    case .notInstalled:
                        if status.canInstall { Button(tr("入れる…")) { model.installAdapter(adapter) }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small).disabled(work != nil) }
                        else { Link(tr("Node.js を入れる"), destination: URL(string: "https://nodejs.org")!).font(.system(size: 12)) }
                    }
                }
            }
            switch work {
            case let .working(text): Label(text, systemImage: "arrow.down.circle").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
            case let .failed(why): Label(why, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
            case .none: EmptyView()
            }
            if case .notInstalled = status {
                Text(tr("\(adapter.agent.rawValue) の CLI は、ACP を話さないので、アダプターが要ります（\(adapter.package)・\(adapter.license)・約 \(adapter.approximateSizeMB) MB）。入れなくても、従来の方式で話せます。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


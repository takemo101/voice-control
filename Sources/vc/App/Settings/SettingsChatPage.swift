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
            Row("会話に使うエージェント", detail: nil) {
                Picker("", selection: Binding(get: { model.settings.chatAgent ?? "apple" }, set: { value in model.update { $0.chatAgent = value == "apple" ? nil : value } })) {
                    ForEach(ChatAgent.allCases, id: \.rawValue) { Text($0.rawValue == "apple" ? "Apple（この Mac の中）" : $0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 190)
            }
            let agent = ChatAgent.parse(model.settings.chatAgent ?? "apple") ?? .apple
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
    }
}

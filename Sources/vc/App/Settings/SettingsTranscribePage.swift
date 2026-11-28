import AppKit
import SwiftUI
import VCCore
import VCSkill
import VCSpeech

/// 音声入力（会議）のページ（F80）：Mac から出ている音＝相手の音声を、文字にする（設定で、自分のマイクも）。**キーを押して話す自分の声は、「音声入力（マイク）」のページ**（別のキー・別の整理）。
/// 作りは、マイクのページと、対：キー・取り込み・整理・履歴。上に、「押すと、何が起きるか」の 3 つの段。
struct TranscribePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let selected = model.settings.transcribeApps?.first ?? ""
        let apps = Self.choices(model.captureApps, selected: selected)
        let tidy = model.settings.tidySystem ?? false, summary = model.settings.summaryAuto ?? false
        let engine = (try? Engine.parse(model.settings.engine ?? "apple")) ?? .apple
        Card(tr("会議の文字起こし"), info: tr("Mac から出ている音（会議・動画など）を、文字にします。画面収録の許可が要ります。音は、残しません。文字は、画面に出し、履歴をオンにしたときだけ、残します。スキルの実行・会話には、使いません。録音・文字起こしには、相手の同意が要る場合があります。")) {
            KeyRow(model: model, kind: .transcribe)
            RowDivider()
            Row(tr("会議のパネル"), detail: tr("開始・停止も、ここから")) {
                Button(tr("開く")) { TranscriptWindow.shared.show() }.controlSize(.small)
            }
            RowDivider()
            Row(tr("相手（Mac から出ている音）"), detail: model.captureAppsMessage ?? tr("既定：すべての音")) {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { selected }, set: { id in model.update(restart: false) { $0.transcribeApps = id.isEmpty ? nil : [id] } })) {
                        Text(tr("すべての音")).tag("")
                        ForEach(apps, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                    }
                    .labelsHidden().frame(width: 170)
                    Button(tr("一覧を読む")) { model.loadCaptureApps() }.controlSize(.small)
                }
            }
            RowDivider()
            SwitchRow(model: model, title: tr("自分のマイクも、文字にする"), detail: tr("ヘッドホンを使ってください"), info: tr("自分のマイクも並べると、会議のやりとりが、相手（左）と自分（右）の、チャットになります。スピーカーで聞いていると、マイクが相手の声を拾うので、ヘッドホンを使ってください。マイクの許可が要ります。"), value: model.settings.transcribeMic ?? false, restart: false) { $0.transcribeMic = $1 ? true : nil }
        }
        Card(tr("整理と要約")) {
            SwitchRow(model: model, title: tr("相手を、整理する"), detail: tr("整えて表示（履歴には、元も残す）"), info: tr("文の確定のたびに、スキルを実行するモデル（設定 > モデル）で整えます。画面には整理後の文字を出し、履歴には、元の文字も残します。数字・否定が変わったときや、遅いとき（10 秒）は、元の文字を使います") + "\n\n" + tr("固定の約束（文字は、データ・内容を足さない・数字と否定を変えない）は、変えられません。その下に、この指示が足されます。声で頼む内容には、使いません。この指示は、音声入力（会議）の整理にも、使います。"), value: tidy, restart: false) { $0.tidySystem = $1 ? true : nil }
            RowDivider()
            SwitchRow(model: model, title: tr("止めたとき、自動で要約する"), detail: tr("会議の Markdown に入れる"), info: tr("会議を止めたとき、要約を作って、会議の Markdown に入れます（既定はオフ）。長い会議は、分けて要約します"), value: summary, restart: false) { $0.summaryAuto = $1 ? true : nil }
            if tidy || summary, let server = engine.server, !server.isLoopback {
                RowDivider()
                Label(tr("同じ LAN のサーバー（\(server.endpoint)）へ、会議の文字が送られます。"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
            }
            RowDivider()
            Collapsible(tr("整え方の指示"), summary: tr("マイクと共通")) { TidyInstructionsEditor(model: model) }
            RowDivider()
            Collapsible(tr("要約のまとめ方の指示"), summary: tr("編集できます")) { SummaryInstructionsEditor(model: model) }
        }
        meetingRecordCard
    }

    /// 保存先のフォルダ（止めたとき、Markdown を書く）と、履歴への入口。
    private var meetingRecordCard: some View {
        let folder = model.settings.meetingFolder
        return Card(tr("保存と履歴"), info: tr("フォルダを選ぶと、会議を止めたときに、1 つの Markdown（日時・要約・相手と自分を分けた文字起こし）を書きます。音声は、残しません。選ばないあいだは、何も書きません（パネルの「…」> 保存… で、いつでも書き出せます）。同じ会議は、同じファイルを書き直します。")) {
            Row(tr("保存先のフォルダ"), detail: folder ?? tr("未設定（自動では、保存しません）")) {
                HStack(spacing: 8) {
                    Button(tr("選ぶ…")) { model.chooseMeetingFolder() }.controlSize(.small)
                    if let folder {
                        Button(tr("開く")) { NSWorkspace.shared.open(URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)) }.controlSize(.small)
                        Button(tr("解除")) { model.clearMeetingFolder() }.controlSize(.small)
                    }
                }
            }
            RowDivider()
            Row(tr("会議の履歴"), detail: (model.settings.history ?? false) ? tr("残す（設定 > 履歴）") : tr("残さない")) {
                Button(tr("履歴を開く")) { model.page = .history }.controlSize(.small)
            }
        }
    }

    /// 選べるアプリ（読んだ一覧。選んであるのに、一覧にないものは、先頭に足す）。
    private static func choices(_ apps: [CaptureApp], selected: String) -> [CaptureApp] {
        guard !selected.isEmpty, !apps.contains(where: { $0.bundleID == selected }) else { return apps }
        return [CaptureApp(bundleID: selected, name: selected)] + apps
    }
}

/// 要約のまとめ方の指示の欄（編集・保存・既定に戻す）。
struct SummaryInstructionsEditor: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("要約のまとめ方の指示（英語でも日本語でも）")).font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $model.summaryInstructionsText)
                .font(.system(size: 12)).frame(height: 130).scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Button(tr("保存")) { model.saveSummaryInstructions() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small)
                Button(tr("既定に戻す")) { model.resetSummaryInstructions() }.controlSize(.small)
                InfoButton(text: tr("固定の約束（話にないことを足さない・名前と数字を変えない）は、変えられません。その下に、この指示が足されます。要約は、スキルを実行するモデル（設定 > モデル）で作ります（クラウドへは、送りません）。話にない数字が出た要約は、出しません。パネルの「…」> 要約…で、いつでも作れます。テーマや、選んだ発話だけの要約もできます。"))
            }
        }
        .padding(14)
    }
}

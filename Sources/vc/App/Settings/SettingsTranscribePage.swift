import AppKit
import SwiftUI
import VCCore
import VCSkill
import VCSpeech

/// 文字起こし（システム音声＝相手の音声。F80）のページ。**自分の声は、「音声入力」のページ**（別のキー・別の設定）。ここは、相手の音声の側の設定：ウィンドウ・キー・取り込む音・整理・履歴。
struct TranscribePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let selected = model.settings.transcribeApps?.first ?? ""
        let apps = Self.choices(model.captureApps, selected: selected)
        let on = model.settings.tidySystem ?? false
        let engine = (try? Engine.parse(model.settings.engine ?? "apple")) ?? .apple
        Card(tr("文字起こし（相手の音声）"), footer: tr("Mac から出ている音（会議・動画など）を、文字にします。画面収録の許可が要ります。音は、残しません。文字は、画面に出し、履歴をオンにしたときだけ、残します。スキルの実行・会話には、使いません。録音・文字起こしには、相手の同意が要る場合があります。自分の声は、「音声入力」のページの設定（キー・整理）で、入力します。")) {
            Row(tr("文字起こしのウィンドウ"), detail: tr("開始と停止は、ウィンドウのボタンか、ショートカットです")) {
                Button(tr("開く")) { TranscriptWindow.shared.show() }.controlSize(.small)
            }
            RowDivider()
            KeyRow(model: model, kind: .transcribe)
            RowDivider()
            Row(tr("取り込む音"), detail: model.captureAppsMessage ?? tr("既定は、Mac から出ている音すべて。アプリを選ぶには、「一覧を読む」")) {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { selected }, set: { id in model.update(restart: false) { $0.transcribeApps = id.isEmpty ? nil : [id] } })) {
                        Text(tr("すべての音")).tag("")
                        ForEach(apps, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                    }
                    .labelsHidden().frame(width: 170)
                    Button(tr("一覧を読む")) { model.loadCaptureApps() }.controlSize(.small)
                }
            }
        }
        Card(tr("整理"), footer: on ? tr("固定の約束（文字は、データ・内容を足さない・数字と否定を変えない）は、変えられません。その下に、この指示が足されます。声で頼む内容には、使いません。この指示は、文字起こし（相手の音声）の整理にも、使います。") : tr("オンにすると、相手の音声の文を、言語モデルで整えます（言い直し・言い間違い・つなぎ言葉・句読点）。自分の声の整理は、「音声入力」のページで、別に決めます。")) {
            SwitchRow(model: model, title: tr("相手の音声を、整理する"), detail: tr("文の確定のたびに、スキルを実行するモデル（設定 > モデル）で整えます。画面には整理後の文字を出し、履歴には、元の文字も残します。数字・否定が変わったときや、遅いとき（10 秒）は、元の文字を使います"), value: on, restart: false) { $0.tidySystem = $1 ? true : nil }
            if on {
                if let server = engine.server, !server.isLoopback {
                    RowDivider()
                    Label(tr("同じ LAN のサーバー（\(server.endpoint)）へ、相手の音声の文字が送られます。"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
                }
            }
            RowDivider()
            TidyInstructionsEditor(model: model)
        }
        Card(tr("履歴")) {
            Row(tr("文字起こしの履歴"), detail: (model.settings.history ?? false) ? tr("残す（設定 > 履歴で、見られます）") : tr("残さない（設定 > 履歴で、オンにします）")) {
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

import AppKit
import SwiftUI
import VCCore
import VCSpeech

/// 文字起こし（システム音声。F80）のページ：ウィンドウ・取り込む音・自分（マイク）。整理は「音声入力」、履歴は「履歴」、キーは「キー」のページ。
struct TranscribePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let selected = model.settings.transcribeApps?.first ?? ""
        var apps = model.captureApps
        if !selected.isEmpty, !apps.contains(where: { $0.bundleID == selected }) { apps.insert(CaptureApp(bundleID: selected, name: selected), at: 0) }
        return Card(tr("文字起こし（相手の音声）"), footer: tr("相手の音声は、Mac から出ている音（会議・動画など）を、文字にします（画面収録の許可が要ります）。自分の声は、マイクを、文字にします（マイクの許可が要ります）。2 つは、別々の経路で、片方だけ・両方を動かせます。音は、残しません。文字は、画面に出し、履歴をオンにしたときだけ、残します。スキルの実行・会話には、使いません。録音・文字起こしには、相手の同意が要る場合があります。両方を同時に使うときは、ヘッドホンを使ってください。")) {
            Row(tr("文字起こしのウィンドウ"), detail: tr("相手の音声と自分の声は、別々に、始め・止められます（ウィンドウのボタンか、ショートカット）")) {
                Button(tr("開く")) { TranscriptWindow.shared.show() }.controlSize(.small)
            }
            RowDivider()
            Row(tr("開始・停止のショートカット"), detail: Self.keySummary(model.settings)) {
                Button(tr("キーを設定")) { model.page = .keys }.controlSize(.small)
            }
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
        Card(tr("整理と履歴"), footer: tr("整理は、「相手」と「自分」を、別々に決めます（設定 > 音声入力）。")) {
            Row(tr("整理"), detail: Self.tidySummary(model.settings)) {
                Button(tr("音声入力で決める")) { model.page = .dictation }.controlSize(.small)
            }
            RowDivider()
            Row(tr("履歴"), detail: (model.settings.history ?? false) ? tr("残す（設定 > 履歴で、見られます）") : tr("残さない")) {
                Button(tr("履歴を開く")) { model.page = .history }.controlSize(.small)
            }
        }
    }

    /// 相手の音声・自分の声の、ショートカット（別々）。
    private static func keySummary(_ settings: VCCore.Settings) -> String {
        func label(_ text: String?) -> String { text.flatMap { HotKeySpec.parse($0).successValue }.map { KeyRow.label(of: $0) } ?? tr("未設定") }
        return tr("相手の音声：\(label(settings.transcribeHotkey))・自分の声：\(label(settings.transcribeMicHotkey))")
    }

    private static func tidySummary(_ settings: VCCore.Settings) -> String {
        switch (settings.tidySystem ?? false, settings.tidy ?? false) {
        case (true, true): return tr("相手：する・自分：する")
        case (true, false): return tr("相手：する・自分：しない")
        case (false, true): return tr("相手：しない・自分：する")
        case (false, false): return tr("相手：しない・自分：しない")
        }
    }
}

private extension Result {
    var successValue: Success? { if case let .success(value) = self { return value } else { return nil } }
}

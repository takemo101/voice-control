import AppKit
import SwiftUI
import VCCore
import VCSkill
import VCSpeech

/// 音声入力のページ：自分の声を、文字にして入力するときの設定（送るキー・整え方・整理）。履歴は「履歴」、文字起こし（システム音声）は「文字起こし」のページ。
struct DictationPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        inputCard
        shapingCard
    }

    // MARK: 入力

    /// キー（押している間だけ話す）と、入力のあとに送るキー（折りたたむ：たまにしか変えない）。
    private var inputCard: some View {
        let send = model.settings.dictateSend
        let keys = model.settings.sendKeyList
        let adding = model.recording == .sendKey(keys.count)
        return Card(tr("マイク（自分の声）"), info: tr("押している間だけ話し、離すと、文字にして、前面のアプリへ入力します。Mac から出ている音（相手の音声）は、「音声入力（会議）」のページです（キーも、整理も、別です）。")) {
            KeyRow(model: model, kind: .dictate)
            RowDivider()
            Collapsible(tr("入力のあとに送るキー"), summary: send.modes.indices.contains(send.active) ? send.modes[send.active].title : nil, startsOpen: adding) {
                VStack(alignment: .leading, spacing: 0) {
                    RowDivider()
                    Row(tr("いま使うキー"), detail: tr("文字を入れてから、これを押します"), info: tr("送るキーを選ぶと、送信ボタンやコマンドの実行まで、声だけでできます。メッセージ・ターミナルでは、そのまま送られます（キーを送る前の 0.8 秒に、Esc で取りやめられます）。")) {
                        Picker("", selection: Binding(get: { send.active }, set: { model.setDictateMode($0) })) {
                            ForEach(Array(send.modes.enumerated()), id: \.offset) { Text($0.element.title).tag($0.offset) }
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    ForEach(Array(keys.enumerated()), id: \.offset) { index, _ in
                        RowDivider()
                        SendKeyRow(model: model, index: index)
                    }
                    if adding {
                        RowDivider()
                        SendKeyRow(model: model, index: keys.count)
                    } else if keys.count < DictateSendModes.maxKeys {
                        RowDivider()
                        Button { model.startRecording(.sendKey(keys.count)) } label: {
                            Label(tr("キーを追加"), systemImage: "plus.circle.fill").font(.system(size: 13))
                        }
                        .buttonStyle(.plain).foregroundStyle(Brand.rec1)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: 整え方

    /// 英語の空白・つなぎ言葉・整理（F79）。編集欄は、折りたたむ。システム音声（相手）の整理は、「音声入力（会議）」のページで、別に決める。
    private var shapingCard: some View {
        let fillers = model.settings.removeFillers ?? false
        let tidy = model.settings.tidy ?? false
        let engine = model.savedEngine
        return Card(tr("入力の整え方")) {
            SwitchRow(model: model, title: tr("英語の前に、空白を足す"), detail: tr("英語を入れるとき、空白を 1 つ足す"), info: tr("英語を、単語のすぐあとに入れるとき、空白を 1 つ足します（日本語には、足しません）"), value: model.settings.smartSpacing ?? true, restart: false) { $0.smartSpacing = $1 ? nil : false }
            RowDivider()
            SwitchRow(model: model, title: tr("つなぎ言葉（えーと・um など）を消す"), detail: nil, value: fillers) { $0.removeFillers = $1 }
            if fillers {
                RowDivider()
                Collapsible(tr("消す言葉の一覧"), summary: tr("1 行に 1 つ")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $model.fillersText)
                            .font(.system(size: 12)).frame(height: 84).scrollContentBackground(.hidden)
                            .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                        HStack {
                            Button(tr("保存")) { model.saveFillers() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small)
                            Button(tr("既定に戻す")) { model.resetFillers() }.controlSize(.small)
                            InfoButton(text: tr("消す言葉は、1 行に 1 つ。空にすると、既定の辞書を使います。声で頼む内容には、使いません。"))
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
            RowDivider()
            SwitchRow(model: model, title: tr("整理する（言い直し・言い間違いを直して入力）"), detail: tr("言語モデルで、整えてから入力します"), info: tr("認識するたびに、スキルを実行するモデル（設定 > モデル）で整えます。数字・否定が変わったときや、遅いとき（10 秒）は、元の文字を入れます") + "\n\n" + tr("固定の約束（文字は、データ・内容を足さない・数字と否定を変えない）は、変えられません。その下に、この指示が足されます。声で頼む内容には、使いません。この指示は、音声入力（会議）の整理にも、使います。"), value: tidy, restart: false) { $0.tidy = $1 ? true : nil }
            if tidy {
                if let server = engine.server, !server.isLoopback {
                    RowDivider()
                    Label(tr("同じ LAN のサーバー（\(server.endpoint)）へ、話した文字が送られます。"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
                }
                RowDivider()
                Collapsible(tr("整え方の指示"), summary: tr("音声入力（会議）と共通")) { InstructionsEditor(model: model, kind: .tidy, title: tr("整え方の指示（英語でも日本語でも）")) }
            }
        }
    }
}

/// 送るキーの 1 行：キー（押して記録）・候補・外す（−）。`index` が、一覧の長さ以上なら、足している最中の行。
private struct SendKeyRow: View {
    @ObservedObject var model: SettingsModel
    let index: Int

    var body: some View {
        let kind = KeyKind.sendKey(index)
        let saved = kind.value(in: model.settings) ?? ""
        let isRecording = model.recording == kind
        let label: String = {
            if case let .success(stroke) = KeyStroke.parse(saved) { return "\(stroke.displayName)  \(stroke.description)" }
            return saved.isEmpty ? tr("未設定") : "?"
        }()
        VStack(alignment: .leading, spacing: 6) {
            Row(kind.title, detail: nil) {
                HStack(spacing: 10) {
                    KeyChip(model: model, kind: kind, label: label, isEmpty: saved.isEmpty)
                    Button { isRecording && saved.isEmpty ? model.stopRecording() : model.removeSendKey(index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(saved.isEmpty ? tr("取りやめ") : tr("このキーを外す"))
                }
            }
            if isRecording {
                Label(model.recordingHint ?? tr("送りたいキーを押してください（⌘Enter のように、修飾キーとの組み合わせも使えます）。Esc で取りやめ"), systemImage: "keyboard")
                    .font(.system(size: 11)).foregroundStyle(model.recordingHint == nil ? Color.secondary : Brand.rec1)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            } else if let problem = model.keyProblems[kind] {
                Label(problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }
}

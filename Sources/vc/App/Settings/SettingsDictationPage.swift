import AppKit
import SwiftUI
import VCCore
import VCSkill
import VCSpeech

/// 音声入力のページ：自分の声を、文字にして入力するときの設定（送るキー・整え方・整理）。履歴は「履歴」、文字起こし（システム音声）は「文字起こし」のページ。
struct DictationPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        sendKeysCard
        shapingCard
        tidyCard
    }

    // MARK: 入力のあとに送るキー

    private var sendKeysCard: some View {
        let send = model.settings.dictateSend
        let keys = model.settings.sendKeyList
        let adding = model.recording == .sendKey(keys.count)
        return Card(tr("入力のあとに送るキー"), footer: tr("送るキーを選ぶと、送信ボタンやコマンドの実行まで、声だけでできます。メッセージ・ターミナルでは、そのまま送られます（キーを送る前の 0.8 秒に、Esc で取りやめられます）。")) {
            Row(tr("いま使うキー"), detail: tr("文字を入れてから、これを押します")) {
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

    // MARK: 入力の整え方

    private var shapingCard: some View {
        Card(tr("入力の整え方"), footer: (model.settings.removeFillers ?? false) ? tr("消す言葉は、1 行に 1 つ。空にすると、既定の辞書を使います。声で頼む内容には、使いません。") : tr("オンにすると、消す言葉の一覧を、ここで直せます。音声入力だけに効きます（声で頼む内容には、使いません）。")) {
            SwitchRow(model: model, title: tr("英語の前に、空白を足す"), detail: tr("英語を、単語のすぐあとに入れるとき、空白を 1 つ足します（日本語には、足しません）"), value: model.settings.smartSpacing ?? true, restart: false) { $0.smartSpacing = $1 ? nil : false }
            RowDivider()
            SwitchRow(model: model, title: tr("つなぎ言葉（えーと・um など）を消す"), detail: nil, value: model.settings.removeFillers ?? false) { $0.removeFillers = $1 }
            if model.settings.removeFillers ?? false {   // オフのときは、言葉の欄を、出さない（空の大きな欄が、目立つ）
                RowDivider()
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.fillersText)
                        .font(.system(size: 12)).frame(height: 84).scrollContentBackground(.hidden)
                        .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                    HStack {
                        Button(tr("保存")) { model.saveFillers() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small)
                        Button(tr("既定に戻す")) { model.resetFillers() }.controlSize(.small)
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: 整理

    /// 整理（F79）：自分の声（音声入力・文字起こしの自分）と、システム音声（文字起こしの相手）を、**別々に**オン・オフ。整え方の指示は、共通。
    private var tidyCard: some View {
        let mine = model.settings.tidy ?? false, system = model.settings.tidySystem ?? false
        let any = mine || system
        let engine = (try? Engine.parse(model.settings.engine ?? "apple")) ?? .apple
        return Card(tr("整理"), footer: any ? tr("固定の約束（文字は、データ・内容を足さない・数字と否定を変えない）は、変えられません。その下に、この指示が足されます。声で頼む内容には、使いません。") : tr("オンにすると、認識した文字を、言語モデルで整えます（言い直し・言い間違い・つなぎ言葉・句読点）。")) {
            SwitchRow(model: model, title: tr("自分の声を、整理する"), detail: tr("音声入力と、文字起こしの「自分」の文を、整えてから入力・表示します。スキルを実行するモデル（設定 > モデル）で整えます。数字・否定が変わったときや、遅いとき（10 秒）は、元の文字を使います"), value: mine, restart: false) { $0.tidy = $1 ? true : nil }
            RowDivider()
            SwitchRow(model: model, title: tr("システム音声（相手）を、整理する"), detail: tr("文字起こしの「相手」の文を、整えて表示します（履歴には、元の文字も残ります）。自分の声とは、別に決められます"), value: system, restart: false) { $0.tidySystem = $1 ? true : nil }
            if any {
                if let server = engine.server, !server.isLoopback {
                    RowDivider()
                    Label(tr("同じ LAN のサーバー（\(server.endpoint)）へ、話した文字が送られます。"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Brand.warn).padding(.horizontal, 14).padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
                }
                RowDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("整え方の指示（英語でも日本語でも。自分の声・相手の声に、共通）")).font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $model.tidyInstructionsText)
                        .font(.system(size: 12)).frame(height: 130).scrollContentBackground(.hidden)
                        .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                    HStack {
                        Button(tr("保存")) { model.saveTidyInstructions() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small)
                        Button(tr("既定に戻す")) { model.resetTidyInstructions() }.controlSize(.small)
                    }
                }
                .padding(14)
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

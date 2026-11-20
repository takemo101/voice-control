import AppKit
import SwiftUI
import VCCore
import VCSpeech

// MARK: 履歴

/// 音声入力の履歴の一覧（検索・コピー・1 件の削除）。ファイルは、`DictationHistory`。**文字は、この画面に出すだけ**（ほかへ、送らない）。
@MainActor final class HistoryList: ObservableObject {
    @Published var query = "" { didSet { reload() } }
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var problem: String?
    private let history = DictationHistory()

    init() { reload() }

    /// 開いたときに、古いものを消して、読み直す。
    func open(days: Int) {
        do { try history.prune(days: days); problem = nil } catch { problem = "\(error)" }
        reload()
    }

    func reload() { entries = history.entries(matching: query) }

    func delete(_ entry: HistoryEntry) {
        do { try history.delete(id: entry.id); problem = nil } catch { problem = "\(error)" }
        reload()
    }

    func clearAll() {
        do { try history.clear(); problem = nil } catch { problem = "\(error)" }
        reload()
    }
}

struct DictationPage: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var list = HistoryList()

    private static let dayChoices = [1, 3, 7, 30, 90, 365]

    var body: some View {
        sendKeysCard
        shapingCard
        historyCard
        EmptyView().onAppear { list.open(days: DictationHistory.days(setting: model.settings.historyDays)) }.onChange(of: model.revision) { _, _ in list.reload() }
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
            RowDivider()
            ForEach(Array(keys.enumerated()), id: \.offset) { index, _ in
                SendKeyRow(model: model, index: index)
                RowDivider()
            }
            if adding {
                SendKeyRow(model: model, index: keys.count)
                RowDivider()
            } else if keys.count < DictateSendModes.maxKeys {
                Button { model.startRecording(.sendKey(keys.count)) } label: {
                    Label(tr("キーを追加"), systemImage: "plus.circle.fill").font(.system(size: 13))
                }
                .buttonStyle(.plain).foregroundStyle(Brand.rec1)
                .padding(.horizontal, 14).padding(.vertical, 10)
                RowDivider()
            }
            KeyRow(model: model, kind: .cycleSend)
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

    // MARK: 履歴

    private var historyCard: some View {
        let on = model.settings.history ?? false
        let days = DictationHistory.days(setting: model.settings.historyDays)
        return VStack(alignment: .leading, spacing: 18) {
            Card(tr("履歴"), footer: on ? tr("古いものは、自動で消えます。1 件ずつ、すべて、消せます。") : tr("オフのあいだは、何も残しません（直前の入力だけは、アプリを終えるまで、メモリに持ちます）。")) {
                SwitchRow(model: model, title: tr("音声入力の履歴を残す"), detail: tr("入力した文字と時刻だけを、この Mac の中に、あなただけが読める形で残します。外へは、送りません"), value: on, restart: false) { $0.history = $1 ? true : nil }
                if on {
                    RowDivider()
                    Row(tr("残す日数"), detail: nil) {
                        Picker("", selection: Binding(get: { days }, set: { value in model.update(restart: false) { $0.historyDays = value == DictationHistory.defaultDays ? nil : value }; list.open(days: value) })) {
                            ForEach(Self.dayChoices.contains(days) ? Self.dayChoices : (Self.dayChoices + [days]).sorted(), id: \.self) { Text(tr("\($0) 日")).tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                    }
                }
            }
            if on || !list.entries.isEmpty {
                Card(tr("入力した文字")) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(tr("探す"), text: $list.query).textFieldStyle(.plain)
                        if !list.query.isEmpty { Button { list.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    RowDivider()
                    if list.entries.isEmpty {
                        Text(list.query.isEmpty ? tr("まだ、ありません") : tr("見つかりません")).font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                    } else {
                        ForEach(Array(list.entries.prefix(200).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { RowDivider() }
                            HistoryRow(entry: entry, copy: { DictationActions.copy(entry.text) }, delete: { list.delete(entry) })
                        }
                        if list.entries.count > 200 { Text(tr("新しい 200 件を表示しています（探すと、絞れます）")).font(.system(size: 11)).foregroundStyle(.secondary).padding(14) }
                    }
                }
                HStack {
                    Button(role: .destructive) { confirmClear() } label: { Text(tr("履歴をすべて消す")) }.controlSize(.small).disabled(list.entries.isEmpty && list.query.isEmpty)
                    if let problem = list.problem { Label(problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red) }
                }
            }
        }
    }

    private func confirmClear() {
        guard AppAlerts.confirm(title: tr("履歴をすべて消しますか？"), message: tr("消した履歴は、戻せません。"), confirm: tr("すべて消す"), style: .warning) else { return }
        list.clearAll()
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let copy: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.date.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: L10n.shared.language.bcp47)))).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(entry.text).font(.system(size: 13)).lineLimit(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: copy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help(tr("コピー"))
            Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help(tr("この 1 件を消す"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
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

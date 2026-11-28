import AppKit
import SwiftUI
import VCCore

/// 履歴の絞り込み：音声入力（自分の声を入力したもの）・文字起こし（システム音声の相手／自分）。
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, dictation, transcript
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return tr("すべて")
        case .dictation: return tr("マイク")
        case .transcript: return tr("会議")
        }
    }

    func matches(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .dictation: return entry.source == nil
        case .transcript: return entry.source != nil
        }
    }
}

/// 履歴の一覧（検索・種類の絞り込み・コピー・1 件の削除）。ファイルは、`DictationHistory`。**文字は、この画面に出すだけ**（ほかへ、送らない）。
@MainActor final class HistoryList: ObservableObject {
    @Published var query = "" { didSet { reload() } }
    @Published var filter = HistoryFilter.all { didSet { reload() } }
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var problem: String?
    private let history = DictationHistory()

    init() { reload() }

    /// 開いたときに、古いものを消して、読み直す。
    func open(days: Int) {
        do { try history.prune(days: days); problem = nil } catch { problem = "\(error)" }
        reload()
    }

    func reload() { entries = history.entries(matching: query).filter(filter.matches) }

    func delete(_ entry: HistoryEntry) {
        do { try history.delete(id: entry.id); problem = nil } catch { problem = "\(error)" }
        reload()
    }

    func clearAll() {
        do { try history.clear(); problem = nil } catch { problem = "\(error)" }
        reload()
    }
}

/// 履歴のページ：音声入力（マイク・会議）の履歴の、オン・オフ・残す日数・一覧。
struct HistoryPage: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var list = HistoryList()

    private static let dayChoices = [1, 3, 7, 30, 90, 365]

    var body: some View {
        let on = model.settings.history ?? false
        let days = DictationHistory.days(setting: model.settings.historyDays)
        Card(tr("履歴"), footer: on ? tr("古いものは、自動で消えます。1 件ずつ、すべて、消せます。") : tr("オフのあいだは、何も残しません（直前の入力だけは、アプリを終えるまで、メモリに持ちます）。")) {
            SwitchRow(model: model, title: tr("音声入力（マイク・会議）の履歴を残す"), detail: tr("文字と時刻だけを、この Mac に残す"), info: tr("入力した文字と時刻だけを、この Mac の中に、あなただけが読める形で残します。外へは送りません。音声・画面は、残しません。文字起こしでは、整理したときの元の文字も、残します"), value: on, restart: false) { $0.history = $1 ? true : nil }
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
        if on || !list.entries.isEmpty || list.filter != .all || !list.query.isEmpty {
            Card(tr("記録")) {
                Picker("", selection: $list.filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.vertical, 10)
                RowDivider()
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
                Button(role: .destructive) { confirmClear() } label: { Text(tr("履歴をすべて消す")) }.controlSize(.small).disabled(list.entries.isEmpty && list.query.isEmpty && list.filter == .all)
                if let problem = list.problem { Label(problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red) }
            }
        }
        EmptyView().onAppear { list.open(days: DictationHistory.days(setting: model.settings.historyDays)) }.onChange(of: model.revision) { _, _ in list.reload() }
    }

    private func confirmClear() {
        guard AppAlerts.confirm(title: tr("履歴をすべて消しますか？"), message: tr("マイクと会議の音声入力の履歴が、すべて消えます。消した履歴は、戻せません。"), confirm: tr("すべて消す"), style: .warning) else { return }
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
                Text(entry.date.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: L10n.shared.language.bcp47)))
                     + (entry.source.map { " · " + TranscriptLog.name($0) } ?? "")).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(entry.text).font(.system(size: 13)).lineLimit(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let raw = entry.raw { Text(tr("元：\(raw)")).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Button(action: copy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help(tr("コピー"))
            Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help(tr("この 1 件を消す"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

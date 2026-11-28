import Foundation
import VCCore
import VCSpeech

/// 文字起こしの記録（メモリ）：確定した文の並びと、確定前の文字（SPEC F80。システム音声＝相手の音声）。**純粋**（画面・音声・モデルを、持たない）：更新の適用・整理後の置き換え・Markdown の書き出し。
struct TranscriptLog: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let date: Date
        /// 表示する文字（整理が通れば、整理後）。
        var text: String
        /// 整理する前の、元の文字（整理しなかった・通らなかったときは、nil）。
        var raw: String?
    }

    private(set) var entries: [Entry] = []

    init() {}
    /// 見た目の確認用（`vc transcript-preview --demo`）：作り物の文を、並べて始める。
    init(entries: [Entry], tentative: String?) { self.entries = entries; self.tentative = tentative }
    /// 確定前の文字（あとで変わる）。
    private(set) var tentative: String?

    /// 認識の更新を、適用する。確定した文が、新しい 1 件になったら、その件を返す（空白だけの文は、足さない）。
    @discardableResult
    mutating func apply(_ update: SegmentTranscriber.Update) -> Entry? {
        let text = Self.normalized(update.text)
        guard update.isFinal else {
            tentative = text.isEmpty ? nil : text
            return nil
        }
        tentative = nil
        guard !text.isEmpty else { return nil }
        let entry = Entry(id: UUID(), date: update.date, text: text, raw: nil)
        entries.append(entry)
        return entry
    }

    /// 整理が通ったとき：表示を、整理後に替える（元は、残す）。
    mutating func replace(id: UUID, tidied: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].text != tidied else { return }
        entries[index].raw = entries[index].text
        entries[index].text = tidied
    }

    /// 空白を整える（認識が、「午後 4時」のように、数字の前後に空白を入れる）：行頭・行末の空白と、連続する空白だけ。文中の 1 つの空白は、そのまま（英語の単語の間）。
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// 吹き出しの並び（チャットの形）：1 件ずつの文と、間が空いたところの時刻の区切り。
    enum Row: Identifiable, Equatable {
        /// 時刻の区切り（前の文から、間が空いた）。
        case separator(Date)
        /// 1 つの吹き出し。`startsGroup`：続けて話した文の、先頭（名前と時刻を出す）。
        case message(Entry, startsGroup: Bool)

        var id: String {
            switch self {
            case let .separator(date): return "sep-\(date.timeIntervalSince1970)"
            case let .message(entry, _): return entry.id.uuidString
            }
        }
    }

    /// 吹き出しの並び。`query` が空でなければ、その文字を含む文だけ（大文字小文字は、区別しない。元の文字も、探す）。
    /// - `groupGap`：これ以内に続いた文は、同じ話の続き（名前・時刻を、繰り返さない）。
    /// - `separatorGap`：これより空いたら、時刻の区切りを入れる。最初の文の前にも、入れる。
    func rows(matching query: String = "", groupGap: TimeInterval = 20, separatorGap: TimeInterval = 300) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = needle.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(needle) || ($0.raw?.localizedCaseInsensitiveContains(needle) ?? false) }
        var rows: [Row] = []
        var previous: Date?
        for entry in shown {
            let gap = previous.map { entry.date.timeIntervalSince($0) }
            if gap == nil || gap! > separatorGap { rows.append(.separator(entry.date)) }
            rows.append(.message(entry, startsGroup: gap == nil || gap! > groupGap))
            previous = entry.date
        }
        return rows
    }

    /// パネルに出す Markdown（Markdown のパネル）：1 件ごとに、時刻と本文。`showOriginal` なら、整理したものに、元の文字を添える。
    func panelMarkdown(showOriginal: Bool = true, locale: Locale = Locale(identifier: "ja_JP")) -> String {
        let time = DateFormatter(); time.locale = locale; time.dateFormat = "HH:mm:ss"
        return entries.map { entry in
            var block = "`\(time.string(from: entry.date))` \(entry.text)"
            if showOriginal, let raw = entry.raw { block += "  \n*\(tr("元：\(raw)"))*" }
            return block
        }.joined(separator: "\n\n")
    }

    /// Markdown（コピー・書き出し用）：見出し＋ 1 件 1 行「- 10:02:11 本文」（整理後の文字だけ）。
    func markdown(title: String, locale: Locale = Locale(identifier: "ja_JP")) -> String {
        let time = DateFormatter(); time.locale = locale; time.dateFormat = "HH:mm:ss"
        var lines = ["# \(title)", ""]
        for entry in entries { lines.append("- \(time.string(from: entry.date)) \(entry.text)") }
        return lines.joined(separator: "\n") + "\n"
    }
}

import Foundation
import VCCore
import VCSpeech

/// 文字起こしの記録（メモリ）：確定した文の並びと、話し手ごとの確定前の文字（SPEC F80。相手＝システム音声・自分＝マイク）。**純粋**（画面・音声・モデルを、持たない）：更新の適用・整理後の置き換え・Markdown の書き出し。
struct TranscriptLog: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let date: Date
        /// 話し手：相手（システム音声）・自分（マイク）。
        let speaker: HistoryEntry.Source
        /// 会議の始まりからの、発話の開始・終わり（秒。字幕の時刻）。
        let start: TimeInterval
        let end: TimeInterval
        /// 表示する文字（整理が通れば、整理後）。
        var text: String
        /// 整理する前の、元の文字（整理しなかった・通らなかったときは、nil）。
        var raw: String?
    }

    private(set) var entries: [Entry] = []
    /// 会議の始まり（最初に始めた時刻。止めて、また始めても、同じ会議の続き）。字幕の時刻の、基準。
    private(set) var meetingStart: Date?

    /// 話し手ごとの、確定前の文字（あとで変わる）。
    private(set) var tentative: [HistoryEntry.Source: String] = [:]

    init() {}
    /// 見た目の確認用（`vc transcript-preview --demo`）：作り物の文を、並べて始める。
    init(entries: [Entry], tentative: [HistoryEntry.Source: String] = [:], meetingStart: Date? = nil) { self.entries = entries; self.tentative = tentative; self.meetingStart = meetingStart }

    /// 会議を始める（すでに始まっていれば、そのまま：続き）。
    mutating func begin(at date: Date) { if meetingStart == nil { meetingStart = date } }

    /// 認識の更新を、適用する。確定した文が、新しい 1 件になったら、その件を返す（空白だけの文は、足さない）。
    @discardableResult
    /// - `origin`：その話し手の認識の「0 秒」が、会議の始まりから、何秒あとか（止めて、また始めたとき、ずれる）。
    mutating func apply(_ update: SegmentTranscriber.Update, speaker: HistoryEntry.Source, origin: TimeInterval = 0) -> Entry? {
        let text = Self.normalized(update.text)
        guard update.isFinal else {
            tentative[speaker] = text.isEmpty ? nil : text
            return nil
        }
        tentative[speaker] = nil
        guard !text.isEmpty else { return nil }
        // 時刻：認識した音の位置があれば、それ。なければ、確定した時刻から、文字数で見積もる（字幕の目安）
        let end: TimeInterval, start: TimeInterval
        if let range = update.range { start = origin + range.lowerBound; end = origin + range.upperBound } else {
            end = max(0, update.date.timeIntervalSince(meetingStart ?? update.date))
            start = max(0, end - min(20, max(1, Double(text.count) * 0.2)))
        }
        // 発話の時刻：認識した音の位置があれば、**話し始めた時刻**（確定した時刻は、間が空くまで、遅れる）。なければ、確定した時刻
        let date = update.range != nil ? (meetingStart?.addingTimeInterval(start) ?? update.date) : update.date
        let entry = Entry(id: UUID(), date: date, speaker: speaker, start: start, end: end, text: text, raw: nil)
        // **話した順**に並べる（確定が届いた順・整理が終わった順では、ない）：相手と自分は、別々に認識して、確定の遅れが、違う。同じ時刻なら、届いた順
        var index = entries.endIndex
        while index > entries.startIndex, entries[index - 1].start > entry.start { index -= 1 }
        entries.insert(entry, at: index)
        return entry
    }

    /// 1 件、消す（発話の 1 行削除）。
    mutating func remove(id: UUID) { entries.removeAll { $0.id == id } }

    /// 整理が通ったとき：表示を、整理後に替える（元は、残す）。
    mutating func replace(id: UUID, tidied: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].text != tidied else { return }
        entries[index].raw = entries[index].text
        entries[index].text = tidied
    }

    /// 話し手の表示名。
    static func name(_ speaker: HistoryEntry.Source) -> String { speaker == .others ? tr("相手") : tr("自分") }

    /// 空白を整える（認識が、「午後 4時」のように、数字の前後に空白を入れる）：行頭・行末の空白と、連続する空白だけ。文中の 1 つの空白は、そのまま（英語の単語の間）。
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// 吹き出しの並び（チャットの形）：1 件ずつの文と、間が空いたところの時刻の区切り。
    enum Row: Identifiable, Equatable {
        /// 時刻の区切り（前の文から、間が空いた）。
        case separator(Date)
        /// 1 つの吹き出し。`startsGroup`：続けて話した文（同じ話し手）の、先頭（名前と時刻を出す）。
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
        var previous: Entry?
        for entry in shown {
            let gap = previous.map { entry.date.timeIntervalSince($0.date) }
            if gap == nil || gap! > separatorGap { rows.append(.separator(entry.date)) }
            // 話し手が替わったら、続きではない（名前と時刻を、出し直す）
            rows.append(.message(entry, startsGroup: gap == nil || gap! > groupGap || previous?.speaker != entry.speaker))
            previous = entry
        }
        return rows
    }

    /// パネルに出す Markdown（Markdown のパネル）：1 件ごとに、時刻と本文。`showOriginal` なら、整理したものに、元の文字を添える。
    func panelMarkdown(showOriginal: Bool = true, locale: Locale = Locale(identifier: "ja_JP")) -> String {
        let time = DateFormatter(); time.locale = locale; time.dateFormat = "HH:mm:ss"
        return entries.map { entry in
            var block = "`\(time.string(from: entry.date))` **\(Self.name(entry.speaker))** \(entry.text)"
            if showOriginal, let raw = entry.raw { block += "  \n*\(tr("元：\(raw)"))*" }
            return block
        }.joined(separator: "\n\n")
    }

    /// テキスト（コピー用）：1 件 1 行「09:31:33 相手: 本文」（整理後の文字だけ。話し手が、分かる）。
    func plainText(locale: Locale = Locale(identifier: "ja_JP")) -> String {
        let time = DateFormatter(); time.locale = locale; time.dateFormat = "HH:mm:ss"
        return entries.map { "\(time.string(from: $0.date)) \(Self.name($0.speaker)): \($0.text)" }.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }

    /// Markdown（コピー・書き出し用）：見出し＋ 1 件 1 行「- 10:02:11 本文」（整理後の文字だけ）。
    func markdown(title: String, locale: Locale = Locale(identifier: "ja_JP")) -> String {
        let time = DateFormatter(); time.locale = locale; time.dateFormat = "HH:mm:ss"
        var lines = ["# \(title)", ""]
        for entry in entries { lines.append("- **\(Self.name(entry.speaker))** \(time.string(from: entry.date)) \(entry.text)") }
        return lines.joined(separator: "\n") + "\n"
    }
}

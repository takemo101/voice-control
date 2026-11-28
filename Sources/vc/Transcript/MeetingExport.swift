import Foundation
import VCCore

/// 要約 1 つ（画面の「要約」のカード・会議の Markdown に入る）。F82。
struct MeetingSummary: Identifiable, Equatable {
    /// 何を要約したか：会議全体・選んだ発話・テーマ。
    enum Scope: Equatable {
        case all
        case selected(count: Int)
        case focus(String)
    }

    let id = UUID()
    let date: Date
    let scope: Scope
    let text: String
}

/// 字幕（SRT・VTT）：1 つの発話を、1 つの字幕に。時刻は、認識した音の位置（会議の始まりからの経過）。話し手の名前を付ける（F81）。**純粋**。
enum Subtitles {
    /// 字幕の並び：始まりの順・終わりは、始まりより後（0.5 秒以上）。
    private static func cues(_ entries: [TranscriptLog.Entry]) -> [(start: TimeInterval, end: TimeInterval, speaker: String, text: String)] {
        entries.sorted { $0.start < $1.start }.compactMap { entry in
            let text = entry.text.replacingOccurrences(of: "-->", with: "→").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty else { return nil }
            let start = max(0, entry.start)
            return (start, max(entry.end, start + 0.5), TranscriptLog.name(entry.speaker), text)
        }
    }

    static func srt(_ entries: [TranscriptLog.Entry]) -> String {
        cues(entries).enumerated().map { index, cue in
            "\(index + 1)\n\(timecode(cue.start, separator: ",")) --> \(timecode(cue.end, separator: ","))\n\(cue.speaker): \(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ entries: [TranscriptLog.Entry]) -> String {
        "WEBVTT\n\n" + cues(entries).map { cue in
            "\(timecode(cue.start, separator: ".")) --> \(timecode(cue.end, separator: "."))\n<v \(escape(cue.speaker))>\(escape(cue.text))\n"
        }.joined(separator: "\n")
    }

    /// `HH:MM:SS,mmm`（SRT）・`HH:MM:SS.mmm`（VTT）。
    static func timecode(_ seconds: TimeInterval, separator: String) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, separator, total % 1000)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// 会議の Markdown（自動保存・「保存…」）：見出し・日時・要約（あれば）・相手と自分を区別した文字起こし。F81・F82。**純粋**（時刻の書き方は、`locale`・`timeZone` で決める）。
struct MeetingDocument {
    let start: Date
    let end: Date
    let entries: [TranscriptLog.Entry]
    let summaries: [MeetingSummary]
    var timeZone = TimeZone.current

    private func format(_ pattern: String, _ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = pattern
        return f.string(from: date)
    }

    var title: String { tr("会議") + " " + format("yyyy-MM-dd HH:mm", start) }

    /// `会議-2026-11-28-0931.md`。
    var fileName: String { "\(tr("会議"))-" + format("yyyy-MM-dd-HHmm", start) + ".md" }

    func markdown() -> String {
        var out = ["# \(title)", ""]
        let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
        out.append("- \(tr("日時"))：\(format("yyyy-MM-dd HH:mm", start))–\(format("HH:mm", end))（\(tr("\(minutes) 分"))）")
        let others = entries.filter { $0.speaker == .others }.count, mine = entries.filter { $0.speaker == .me }.count
        out.append("- \(tr("発話"))：\(TranscriptLog.name(.others)) \(tr("\(others) 件"))・\(TranscriptLog.name(.me)) \(tr("\(mine) 件"))")   // l10n-skip：書き出す文書の区切り（画面の文言ではない）
        out.append("")
        // 要約：会議全体（最新の 1 つ）→ ピックアップ（選んだ発話・テーマ）
        if let overall = summaries.last(where: { $0.scope == .all }) {
            out += ["## \(tr("要約"))", "", "*\(tr("言語モデルによる要約です（言い換え）。正確さは、文字起こしで確かめてください。"))*", "", overall.text, ""]
        }
        for pick in summaries where pick.scope != .all {
            let heading: String
            switch pick.scope {
            case let .focus(topic): heading = tr("ピックアップ：\(topic.split(whereSeparator: \.isNewline).joined(separator: " "))")
            case let .selected(count): heading = tr("ピックアップ：選んだ \(count) 件")
            case .all: heading = ""
            }
            out += ["## \(heading)", "", pick.text, ""]
        }
        out += ["## \(tr("文字起こし"))", ""]
        for entry in entries { out.append("- **\(TranscriptLog.name(entry.speaker))** \(format("HH:mm:ss", entry.date)) \(entry.text)") }
        return out.joined(separator: "\n") + "\n"
    }
}

/// 会議の Markdown を、フォルダへ書く（F81）：自分だけが読める（0600）。**止めて、また始めたら、同じファイルを書き直す**（同じ会議の続き）。
enum MeetingWriter {
    enum Failure: Error, CustomStringConvertible {
        case cannotWrite(String)
        var description: String {
            switch self {
            case let .cannotWrite(why): return tr("会議の記録を書けませんでした（\(why)）")
            }
        }
    }

    /// `existing`（この会議が、すでに書いたファイル）があれば、そこへ。なければ、`fileName` で、同じ名前を避けて作る。書いた場所を返す。
    static func write(_ markdown: String, fileName: String, in folder: URL, existing: URL?) throws -> URL {
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { throw Failure.cannotWrite(error.localizedDescription) }
        let target = existing ?? uniqueURL(fileName, in: folder)
        try writeFile(markdown, to: target)
        return target
    }

    /// 利用者が選んだ場所（保存のパネル）へ、書く（0600。同じ場所なら、置き換える）。**一時ファイルに書いてから移す**：失敗したら、一時ファイルを、消す（会議の文字が、残らない）。
    static func writeFile(_ text: String, to url: URL) throws {
        let manager = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".meeting-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { throw Failure.cannotWrite(tr("ファイルを作れません")) }
        do {
            if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: temporary) } else { try manager.moveItem(at: temporary, to: url) }
        } catch {
            try? manager.removeItem(at: temporary)   // try?: 片付け（消せなくても、書けなかった失敗を、先に伝える）
            throw Failure.cannotWrite(error.localizedDescription)
        }
    }

    /// 同じ名前があれば、`-2`・`-3` …を付ける。
    static func uniqueURL(_ fileName: String, in folder: URL) -> URL {
        let base = (fileName as NSString).deletingPathExtension, ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName), n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }
}

import Foundation
import Testing
@testable import vc
import VCCore

/// 会議の書き出し（F81・F82）：字幕（SRT・VTT）・会議の Markdown・ファイルへの書き込み。
@Suite struct MeetingExportTests {
    private func entry(_ speaker: HistoryEntry.Source, _ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptLog.Entry {
        .init(id: UUID(), date: Date(timeIntervalSince1970: 1_800_000_000 + start), speaker: speaker, start: start, end: end, text: text, raw: nil)
    }

    @Test func srtHasNumberedCuesWithSpeakerNamesAndCommaTimecodes() {
        let srt = Subtitles.srt([entry(.others, 1.5, 4.25, "こんにちは。"), entry(.me, 5, 7, "はじめまして。")])
        #expect(srt == "1\n00:00:01,500 --> 00:00:04,250\n相手: こんにちは。\n\n2\n00:00:05,000 --> 00:00:07,000\n自分: はじめまして。\n")
    }

    @Test func vttUsesVoiceTagsDotTimecodesAndEscapesMarkup() {
        let vtt = Subtitles.vtt([entry(.others, 3_725.0, 3_727, "A & B <c>")])
        #expect(vtt == "WEBVTT\n\n01:02:05.000 --> 01:02:07.000\n<v 相手>A &amp; B &lt;c&gt;\n")
    }

    @Test func cuesAreSortedNeverEndBeforeTheyStartAndBlankOnesAreSkipped() {
        let srt = Subtitles.srt([entry(.me, 10, 9, "後"), entry(.others, 2, 3, "先"), entry(.others, 4, 5, "  \n  "), entry(.others, 6, 7, "→ をふくむ --> 文")])
        let cues = srt.components(separatedBy: "\n\n")
        #expect(cues.count == 3 && cues[0].hasPrefix("1\n00:00:02,000") && cues[2].contains("00:00:10,000 --> 00:00:10,500"))   // 終わりが始まりより前：0.5 秒に
        #expect(!srt.contains("-->  ") && srt.contains("→ をふくむ → 文"))   // 本文の `-->` は、字幕の区切りと、混ざらない
    }

    @Test func theMeetingMarkdownTellsTheOtherPartyFromMeAndPutsTheSummaryFirst() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [entry(.others, 0, 3, "来週のリリースは3日です。"), entry(.me, 5, 7, "了解です。")]
        let summaries = [MeetingSummary(date: start, scope: .all, text: "- リリースは 3 日"), MeetingSummary(date: start, scope: .focus("日程"), text: "- 3 日")]
        let doc = MeetingDocument(start: start, end: start.addingTimeInterval(1_860), entries: entries, summaries: summaries, timeZone: utc)
        let md = doc.markdown()
        #expect(md.hasPrefix("# 会議 2027-01-15 08:00\n") && doc.fileName == "会議-2027-01-15-0800.md")
        #expect(md.contains("（31 分）") && md.contains("相手 1 件・自分 1 件"))
        #expect(md.contains("## 要約") && md.contains("- リリースは 3 日") && md.contains("## ピックアップ：日程"))
        #expect(md.contains("- **相手** 08:00:00 来週のリリースは3日です。") && md.contains("- **自分** 08:00:05 了解です。"))
        let summaryAt = try #require(md.range(of: "## 要約")), transcriptAt = try #require(md.range(of: "## 文字起こし"))
        #expect(summaryAt.lowerBound < transcriptAt.lowerBound)   // 要約が、先
    }

    @Test func withoutASummaryThereIsNoSummarySectionAndTheLatestOverallOneWins() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let none = MeetingDocument(start: start, end: start, entries: [], summaries: []).markdown()
        #expect(!none.contains("## 要約"))
        let two = MeetingDocument(start: start, end: start, entries: [], summaries: [MeetingSummary(date: start, scope: .all, text: "古い"), MeetingSummary(date: start, scope: .all, text: "新しい")]).markdown()
        #expect(two.contains("新しい") && !two.contains("古い"))
    }

    @Test func writingKeepsOwnerOnlyPermissionsAvoidsNameClashesAndRewritesTheSameMeeting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vc-meeting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try MeetingWriter.write("A", fileName: "会議.md", in: folder, existing: nil)
        let second = try MeetingWriter.write("B", fileName: "会議.md", in: folder, existing: nil)   // 別の会議が、同じ名前：上書きしない
        #expect(first.lastPathComponent == "会議.md" && second.lastPathComponent == "会議-2.md")
        let again = try MeetingWriter.write("A2", fileName: "会議.md", in: folder, existing: first)  // 同じ会議の続き：同じファイルを書き直す
        let firstText = try String(contentsOf: first, encoding: .utf8), secondText = try String(contentsOf: second, encoding: .utf8)
        #expect(again == first && firstText == "A2" && secondText == "B")
        let mode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }
}

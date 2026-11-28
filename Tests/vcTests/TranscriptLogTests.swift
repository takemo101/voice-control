import Foundation
import Testing
@testable import vc
import VCCore
import VCSpeech

/// 文字起こしの記録（F80）：更新の適用・整理後の置き換え・Markdown。
@Suite struct TranscriptLogTests {
    private func update(_ text: String, final: Bool, at seconds: TimeInterval = 0) -> SegmentTranscriber.Update {
        SegmentTranscriber.Update(text: text, isFinal: final, date: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    @Test func tentativeTextIsKeptPerSpeakerAndAFinalSentenceBecomesOneEntryAndClearsOnlyThatSpeakers() {
        var log = TranscriptLog()
        #expect(log.apply(update("今日は", final: false), speaker: .others) == nil)
        log.apply(update("今日はいい", final: false), speaker: .others)
        log.apply(update("了解です", final: false), speaker: .me)
        #expect(log.tentative == [.others: "今日はいい", .me: "了解です"] && log.entries.isEmpty)   // 確定前は、置き換わる・話し手ごと
        let entry = log.apply(update("今日はいい天気ですね。", final: true), speaker: .others)
        #expect(entry?.text == "今日はいい天気ですね。" && entry?.speaker == .others && entry?.raw == nil)
        #expect(log.entries.count == 1 && log.tentative == [.me: "了解です"])   // 自分の確定前は、そのまま
    }

    @Test func blankFinalsAreIgnoredAndSpacesAreTidiedButASingleSpaceInsideStays() {
        var log = TranscriptLog()
        #expect(log.apply(update("  \n ", final: true), speaker: .others) == nil && log.entries.isEmpty)
        let entry = log.apply(update("  午後  4時からです  ", final: true), speaker: .others)
        #expect(entry?.text == "午後 4時からです")
    }

    @Test func aTidiedTextReplacesTheDisplayedOneAndKeepsTheOriginalOnlyWhenItChanged() throws {
        var log = TranscriptLog()
        let first = log.apply(update("えーと明日は3時、いや4時です", final: true), speaker: .others)
        let entry = try #require(first)
        log.replace(id: entry.id, tidied: "明日は4時です。")
        #expect(log.entries[0].text == "明日は4時です。" && log.entries[0].raw == "えーと明日は3時、いや4時です")
        let second = log.apply(update("そのままです", final: true), speaker: .others)
        let same = try #require(second)
        log.replace(id: same.id, tidied: "そのままです")   // 変わらなければ、元は、残さない
        #expect(log.entries[1].raw == nil)
    }

    @Test func thePanelShowsEachSentenceWithItsTimeAndTheOriginalOnlyWhenItWasTidied() throws {
        var log = TranscriptLog()
        let first = log.apply(update("えーと明日は3時、いや4時です", final: true), speaker: .others)
        log.apply(update("そのままです", final: true), speaker: .others)
        log.replace(id: try #require(first).id, tidied: "明日は4時です。")
        let panel = log.panelMarkdown()
        #expect(panel.contains("明日は4時です。") && panel.contains("えーと明日は3時、いや4時です") && panel.contains("そのままです"))
        #expect(!log.panelMarkdown(showOriginal: false).contains("えーと"))   // コピー・書き出しには、元を出さない
    }

    /// チャットの並び：続けて話した文はまとめ（先頭だけ名前・時刻）・間が空いたら、時刻の区切り・探すと、含む文だけ。
    @Test func rowsGroupSentencesSpokenCloseTogetherAndSeparateLongPauses() {
        var log = TranscriptLog()
        log.apply(update("一つ目です。", final: true, at: 0), speaker: .others)
        log.apply(update("二つ目です。", final: true, at: 10), speaker: .others)     // 10 秒後：同じ話の続き
        log.apply(update("三つ目です。", final: true, at: 40), speaker: .others)     // 30 秒後：新しい話（区切りは、なし）
        log.apply(update("四つ目です。", final: true, at: 1000), speaker: .others)   // 16 分後：時刻の区切り
        let rows = log.rows()
        let shape = rows.map { row -> String in
            switch row {
            case .separator: return "—"
            case let .message(_, startsGroup): return startsGroup ? "先" : "続"
            }
        }
        #expect(shape == ["—", "先", "続", "先", "—", "先"])
        let found = log.rows(matching: "二つ目")
        #expect(found.count == 2)   // 区切り＋その 1 文
        #expect(log.rows(matching: "ありません").isEmpty)
    }

    @Test func searchAlsoFindsTheOriginalTextOfATidiedSentence() throws {
        var log = TranscriptLog()
        let entry = log.apply(update("えーと明日は3時、いや4時です", final: true), speaker: .others)
        log.replace(id: try #require(entry).id, tidied: "明日は4時です。")
        #expect(log.rows(matching: "3時").count == 2)   // 元の文字にだけある語でも、見つかる
    }

    /// コピー・書き出しで、相手と自分が、区別できる（Markdown・テキスト・パネル）。
    @Test func exportsTellTheOtherPartyFromMe() {
        var log = TranscriptLog()
        log.apply(update("こんにちは。", final: true, at: 0), speaker: .others)
        log.apply(update("はじめまして。", final: true, at: 5), speaker: .me)
        let markdown = log.markdown(title: "会議")
        #expect(markdown.hasPrefix("# 会議\n") && markdown.contains("**相手**") && markdown.contains("**自分**"))
        let lines = markdown.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines.count == 2 && lines[0].contains("相手") && lines[0].contains("こんにちは。") && lines[1].contains("自分") && lines[1].contains("はじめまして。"))
        let text = log.plainText().split(separator: "\n").map(String.init)
        #expect(text.count == 2 && text[0].contains("相手: こんにちは。") && text[1].contains("自分: はじめまして。"))
        #expect(log.panelMarkdown().contains("**相手**") && log.panelMarkdown().contains("**自分**"))
    }

    /// 並びは、話した順（確定が届いた順ではない）：相手の確定は、間が空くまで遅れるので、あとに話した自分が、先に確定することがある。
    @Test func entriesAreOrderedByWhenTheyWereSpokenNotByWhenTheyArrived() throws {
        var log = TranscriptLog()
        let began = Date(timeIntervalSince1970: 1_800_000_000)
        log.begin(at: began)
        func final(_ text: String, _ start: TimeInterval, _ end: TimeInterval, _ speaker: HistoryEntry.Source) {
            log.apply(SegmentTranscriber.Update(text: text, isFinal: true, date: began.addingTimeInterval(60), range: start...end), speaker: speaker)
        }
        final("自分の返事。", 20, 22, .me)            // あとに話したが、先に確定した
        final("相手の長い話。", 5, 18, .others)       // 先に話したが、あとに確定した
        final("相手の続き。", 30, 33, .others)
        #expect(log.entries.map(\.text) == ["相手の長い話。", "自分の返事。", "相手の続き。"])
        #expect(log.entries[0].date == began.addingTimeInterval(5) && log.entries[1].date == began.addingTimeInterval(20))   // 時刻も、話し始め
        // 整理で、文字が替わっても、並びは、動かない
        let id = try #require(log.entries.first { $0.text == "自分の返事。" }?.id)
        log.replace(id: id, tidied: "整えた返事。")
        #expect(log.entries.map(\.speaker) == [.others, .me, .others])
    }

    @Test func aChangeOfSpeakerStartsANewGroupEvenWhenTheyAnswerQuickly() {
        var log = TranscriptLog()
        log.apply(update("質問です。", final: true, at: 0), speaker: .others)
        log.apply(update("はい。", final: true, at: 2), speaker: .me)        // 2 秒後でも、話し手が替わった：先頭
        log.apply(update("続けます。", final: true, at: 4), speaker: .me)    // 同じ話し手が続く：まとめる
        let groups = log.rows().compactMap { row -> Bool? in if case let .message(_, start) = row { return start } else { return nil } }
        #expect(groups == [true, true, false])
    }
}

/// 相手（会議の音）の整理は `tidySystem`・自分の声の整理は `tidy`：別々のスイッチ（F79・F80）。
@Suite struct TranscriptTidySwitchTests {
    @Test func theOtherPartyAndMyOwnVoiceAreTidiedIndependently() {
        var settings = Settings()
        #expect(!TranscriptSession.tidies(.others, settings: settings) && !TranscriptSession.tidies(.me, settings: settings))
        settings.tidySystem = true
        #expect(TranscriptSession.tidies(.others, settings: settings) && !TranscriptSession.tidies(.me, settings: settings))
        settings.tidySystem = nil; settings.tidy = true
        #expect(!TranscriptSession.tidies(.others, settings: settings) && TranscriptSession.tidies(.me, settings: settings))
    }
}

/// 履歴の絞り込み：音声入力（source なし）と文字起こし（source あり）。
@Suite struct HistoryFilterTests {
    @Test func dictationAndTranscriptEntriesAreToldApartBySource() {
        let typed = HistoryEntry(date: Date(), text: "入力した文字")
        let heard = HistoryEntry(date: Date(), text: "相手の文字", source: .others)
        #expect(HistoryFilter.dictation.matches(typed) && !HistoryFilter.dictation.matches(heard))
        #expect(!HistoryFilter.transcript.matches(typed) && HistoryFilter.transcript.matches(heard))
        #expect(HistoryFilter.all.matches(typed) && HistoryFilter.all.matches(heard))
    }
}

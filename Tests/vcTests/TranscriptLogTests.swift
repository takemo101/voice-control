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

    @Test func tentativeTextIsReplacedAndAFinalSentenceBecomesOneEntryAndClearsIt() {
        var log = TranscriptLog()
        #expect(log.apply(update("今日は", final: false)) == nil)
        log.apply(update("今日はいい", final: false))
        #expect(log.tentative == "今日はいい" && log.entries.isEmpty)   // 確定前は、置き換わる（足されない）
        let entry = log.apply(update("今日はいい天気ですね。", final: true))
        #expect(entry?.text == "今日はいい天気ですね。" && entry?.raw == nil)
        #expect(log.entries.count == 1 && log.tentative == nil)
    }

    @Test func blankFinalsAreIgnoredAndSpacesAreTidiedButASingleSpaceInsideStays() {
        var log = TranscriptLog()
        #expect(log.apply(update("  \n ", final: true)) == nil && log.entries.isEmpty)
        let entry = log.apply(update("  午後  4時からです  ", final: true))
        #expect(entry?.text == "午後 4時からです")
    }

    @Test func aTidiedTextReplacesTheDisplayedOneAndKeepsTheOriginalOnlyWhenItChanged() throws {
        var log = TranscriptLog()
        let first = log.apply(update("えーと明日は3時、いや4時です", final: true))
        let entry = try #require(first)
        log.replace(id: entry.id, tidied: "明日は4時です。")
        #expect(log.entries[0].text == "明日は4時です。" && log.entries[0].raw == "えーと明日は3時、いや4時です")
        let second = log.apply(update("そのままです", final: true))
        let same = try #require(second)
        log.replace(id: same.id, tidied: "そのままです")   // 変わらなければ、元は、残さない
        #expect(log.entries[1].raw == nil)
    }

    @Test func thePanelShowsEachSentenceWithItsTimeAndTheOriginalOnlyWhenItWasTidied() throws {
        var log = TranscriptLog()
        let first = log.apply(update("えーと明日は3時、いや4時です", final: true))
        log.apply(update("そのままです", final: true))
        log.replace(id: try #require(first).id, tidied: "明日は4時です。")
        let panel = log.panelMarkdown()
        #expect(panel.contains("明日は4時です。") && panel.contains("えーと明日は3時、いや4時です") && panel.contains("そのままです"))
        #expect(!log.panelMarkdown(showOriginal: false).contains("えーと"))   // コピー・書き出しには、元を出さない
    }

    /// チャットの並び：続けて話した文はまとめ（先頭だけ名前・時刻）・間が空いたら、時刻の区切り・探すと、含む文だけ。
    @Test func rowsGroupSentencesSpokenCloseTogetherAndSeparateLongPauses() {
        var log = TranscriptLog()
        log.apply(update("一つ目です。", final: true, at: 0))
        log.apply(update("二つ目です。", final: true, at: 10))     // 10 秒後：同じ話の続き
        log.apply(update("三つ目です。", final: true, at: 40))     // 30 秒後：新しい話（区切りは、なし）
        log.apply(update("四つ目です。", final: true, at: 1000))   // 16 分後：時刻の区切り
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
        let entry = log.apply(update("えーと明日は3時、いや4時です", final: true))
        log.replace(id: try #require(entry).id, tidied: "明日は4時です。")
        #expect(log.rows(matching: "3時").count == 2)   // 元の文字にだけある語でも、見つかる
    }

    @Test func theMarkdownListsEachEntryWithItsTime() {
        var log = TranscriptLog()
        log.apply(update("こんにちは。", final: true, at: 0))
        log.apply(update("はじめまして。", final: true, at: 5))
        let markdown = log.markdown(title: "文字起こし")
        #expect(markdown.hasPrefix("# 文字起こし\n") && markdown.contains("こんにちは。") && markdown.contains("はじめまして。"))
    }
}

/// システム音声（相手の音声）の整理は、自分の声（音声入力）の整理とは、別の設定（F79・F80）。
@Suite struct TranscriptTidySwitchTests {
    @Test func theOtherPartysAudioIsTidiedOnlyByItsOwnSwitchNotByTheDictationOne() {
        var settings = Settings()
        #expect(!TranscriptSession.tidies(settings: settings))
        settings.tidy = true   // 自分の声の整理：相手の音声には、効かない
        #expect(!TranscriptSession.tidies(settings: settings))
        settings.tidySystem = true
        #expect(TranscriptSession.tidies(settings: settings))
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

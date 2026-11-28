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

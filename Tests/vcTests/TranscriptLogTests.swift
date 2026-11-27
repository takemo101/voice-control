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

    @Test func tentativeTextIsKeptPerSpeakerAndAFinalSentenceBecomesOneEntryAndClearsIt() {
        var log = TranscriptLog()
        #expect(log.apply(update("今日は", final: false), speaker: .others) == nil)
        log.apply(update("こんにちは", final: false), speaker: .me)
        #expect(log.tentative == [.others: "今日は", .me: "こんにちは"] && log.entries.isEmpty)
        let entry = log.apply(update("今日はいい天気ですね。", final: true), speaker: .others)
        #expect(entry?.text == "今日はいい天気ですね。" && entry?.speaker == .others && entry?.raw == nil)
        #expect(log.entries.count == 1 && log.tentative == [.me: "こんにちは"])   // 自分の確定前は、そのまま
    }

    @Test func blankFinalsAreIgnoredAndSpacesAreTidiedButASingleSpaceInsideStays() {
        var log = TranscriptLog()
        #expect(log.apply(update("  \n ", final: true), speaker: .others) == nil && log.entries.isEmpty)
        let entry = log.apply(update("  午後  4時からです  ", final: true), speaker: .others)
        #expect(entry?.text == "午後 4時からです")
    }

    @Test func aTidiedTextReplacesTheDisplayedOneAndKeepsTheOriginalOnlyWhenItChanged() throws {
        var log = TranscriptLog()
        let first = log.apply(update("えーと明日は3時、いや4時です", final: true), speaker: .me)
        let entry = try #require(first)
        log.replace(id: entry.id, tidied: "明日は4時です。")
        #expect(log.entries[0].text == "明日は4時です。" && log.entries[0].raw == "えーと明日は3時、いや4時です")
        let second = log.apply(update("そのままです", final: true), speaker: .others)
        let same = try #require(second)
        log.replace(id: same.id, tidied: "そのままです")   // 変わらなければ、元は、残さない
        #expect(log.entries[1].raw == nil)
    }

    @Test func theMarkdownListsEachEntryWithItsSpeaker() {
        var log = TranscriptLog()
        log.apply(update("こんにちは。", final: true, at: 0), speaker: .others)
        log.apply(update("はじめまして。", final: true, at: 5), speaker: .me)
        let markdown = log.markdown(title: "文字起こし")
        #expect(markdown.hasPrefix("# 文字起こし\n") && markdown.contains("**相手**") && markdown.contains("こんにちは。") && markdown.contains("**自分**") && markdown.contains("はじめまして。"))
    }
}

/// 整理は、相手（システム音声）と自分で、別々に決める（F79・F80）。
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

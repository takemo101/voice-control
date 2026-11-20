import Foundation
import Testing
@testable import VCCore

/// 言語の登録：**どの言語も、同じ形の、言語ごとのデータを持つ**（言語を足したときに、足し忘れ・取り違えが、ここで分かる）。
@Suite struct LanguageProfileTests {
    @Test func everyRegisteredLanguageHasCompleteAndConsistentData() {
        #expect(AppLanguage.allCases.contains(.ja) && AppLanguage.allCases.contains(.en))   // 日本語（鍵）・英語（引き先）は、必ず、ある
        #expect(Set(AppLanguage.allCases.map(\.rawValue)).count == AppLanguage.allCases.count)   // 符号は、重ならない
        for language in AppLanguage.allCases {
            let profile = language.profile
            #expect(!profile.displayName.isEmpty && !profile.englishName.isEmpty, "\(language)")
            #expect(profile.whisperCode == language.rawValue, "\(language)：Whisper の符号は、言語の符号")
            #expect(profile.bcp47.lowercased().hasPrefix(language.rawValue + "-"), "\(language)：Locale は、言語の符号で始まる")
            #expect(!profile.nlCode.isEmpty && !profile.affirmatives.isEmpty && !profile.fillers.isEmpty, "\(language)：はい・つなぎ言葉は、1 つはある")
            #expect(!profile.chatStopPhrases.isEmpty, "\(language)：ストップワードは、1 つはある")
            #expect(profile.affirmatives.allSatisfy { $0 == $0.lowercased() && !$0.isEmpty }, "\(language)：「はい」の言い方は、小文字")
            #expect(AppLanguage.parse(language.rawValue.uppercased()) == language)             // 設定の書き方（大文字小文字は、問わない）
        }
        #expect(AppLanguage.parse("xx") == nil && AppLanguage.parse(nil) == nil)
    }

    @Test func speechLanguagesAreTheRegisteredOnesPlusAuto() {
        let all = SpeechLanguage.allCases
        #expect(all.count == AppLanguage.allCases.count + 1 && all.last == .auto)
        for language in AppLanguage.allCases {
            #expect(SpeechLanguage.parse(language.rawValue) == .fixed(language) && SpeechLanguage.fixed(language).rawValue == language.rawValue)
            #expect(SpeechLanguage.fixed(language).whisperCode == language.whisperCode)
        }
        #expect(SpeechLanguage.parse("AUTO") == .auto && SpeechLanguage.auto.rawValue == "auto" && SpeechLanguage.auto.whisperCode == nil)
        #expect(SpeechLanguage.parse("klingon") == nil)
    }

    @Test func theMacLanguageIsMatchedAgainstEveryRegisteredLanguage() {
        for language in AppLanguage.allCases {
            #expect(SpeechLanguage.auto.resolved(systemLanguages: [language.profile.bcp47, "zz-ZZ"]) == language)   // `ja-JP`・`en-US`…
            #expect(SpeechLanguage.auto.resolved(systemLanguages: [language.rawValue]) == language)                  // 地域なし
        }
        #expect(SpeechLanguage.auto.resolved(systemLanguages: ["zz-ZZ"]) == .en && SpeechLanguage.auto.resolved(systemLanguages: []) == .en)   // 登録のない言語は、英語
    }

    @Test func thePhraseListsAreTheUnionOfAllLanguages() {
        #expect(AppLanguage.allAffirmatives.contains("はい") && AppLanguage.allAffirmatives.contains("go ahead"))
        #expect(AppLanguage.allFillers.contains("えーと") && AppLanguage.allFillers.contains("um"))
        #expect(AppLanguage.allChatEndPhrases.contains("会話を終わ") && AppLanguage.allChatForgetPhrases.contains("忘れて"))
    }
}

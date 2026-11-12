import Testing
@testable import VCSpeech

/// 読み上げの声の選び方：品質がいちばん高い声を、自動で。面白い声は、選ばない。利用者が決めた声が、あれば、それ。
@Suite struct SpeechVoiceTests {
    private func voice(_ id: String, _ name: String, _ quality: Int, _ language: String = "ja-JP") -> SpeechVoice.Info {
        SpeechVoice.Info(identifier: id, name: name, language: language, quality: quality)
    }

    private var kyoko: SpeechVoice.Info { voice("com.apple.voice.compact.ja-JP.Kyoko", "Kyoko", 1) }
    private var eddy: SpeechVoice.Info { voice("com.apple.eloquence.ja-JP.Eddy", "Eddy", 1) }
    private var otoya: SpeechVoice.Info { voice("com.apple.voice.premium.ja-JP.Otoya", "Otoya", 3) }
    private var kyokoEnhanced: SpeechVoice.Info { voice("com.apple.voice.enhanced.ja-JP.Kyoko", "Kyoko（拡張）", 2) }

    @Test func theHighestQualityVoiceWins() {
        #expect(SpeechVoice.best([kyoko, kyokoEnhanced, otoya])?.name == "Otoya")
        #expect(SpeechVoice.best([kyoko, kyokoEnhanced])?.name == "Kyoko（拡張）")
    }

    @Test func noveltyVoicesLoseToNormalOnesOfTheSameQuality() {
        #expect(SpeechVoice.best([eddy, kyoko])?.name == "Kyoko")   // 標準どうしなら、面白くない声
        #expect(SpeechVoice.best([eddy])?.name == "Eddy")           // ほかになければ、それを使う
    }

    @Test func nonJapaneseVoicesAreIgnoredAndNothingMeansNil() {
        #expect(SpeechVoice.best([voice("com.apple.voice.premium.en-US.Ava", "Ava", 3, "en-US")]) == nil)
        #expect(SpeechVoice.best([]) == nil)
    }

    @Test func aPreferredVoiceWinsByNameOrIdentifierCaseInsensitively() {
        let all = [kyoko, kyokoEnhanced, otoya]
        #expect(SpeechVoice.resolve(preferred: "kyoko", voices: all)?.name == "Kyoko")
        #expect(SpeechVoice.resolve(preferred: "COM.APPLE.VOICE.ENHANCED.JA-JP.KYOKO", voices: all)?.name == "Kyoko（拡張）")
    }

    @Test func aMissingOrAutoPreferenceFallsBackToTheBest() {
        let all = [kyoko, otoya]
        #expect(SpeechVoice.resolve(preferred: nil, voices: all)?.name == "Otoya")
        #expect(SpeechVoice.resolve(preferred: "auto", voices: all)?.name == "Otoya")
        #expect(SpeechVoice.resolve(preferred: "Nobody", voices: all)?.name == "Otoya")   // 消えた声は、自動に
        #expect(SpeechVoice.resolve(preferred: "", voices: all)?.name == "Otoya")
    }
}

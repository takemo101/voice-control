import Testing
import VCCore
@testable import vc

/// 設定画面の規則：キーの書き方・重なり・エンジンの組み立て（画面なし）。
@Suite struct SettingsRulesTests {
    @Test func aValidKeyHasNoProblemAndABadSpellingIsExplained() {
        let settings = Settings()
        #expect(SettingsRules.keyProblem(.listen, text: "ctrl+opt+space", in: settings) == nil)
        #expect(SettingsRules.keyProblem(.dictate, text: "rcmd", in: settings) == nil)
        #expect(SettingsRules.keyProblem(.dictate, text: "bogus-key", in: settings) != nil)
    }

    @Test func overlapsWithOtherKeysAreReportedForTheKeyBeingEdited() {
        var settings = Settings()
        settings.hotkey = "rshift"
        settings.dictateHotkey = "rcmd"
        #expect(SettingsRules.keyProblem(.chat, text: "ropt", in: settings) == nil)
        #expect(SettingsRules.keyProblem(.chat, text: "rcmd", in: settings)?.contains("音声入力") == true)
        #expect(SettingsRules.keyProblem(.chat, text: "rshift", in: settings)?.contains("声で頼む") == true)
        // 声で頼むキーの既定（shift）も、重なりに数える
        var defaults = Settings()
        defaults.chatHotkey = nil
        #expect(SettingsRules.keyProblem(.dictate, text: "shift", in: defaults)?.contains("重なり") == true)
    }

    @Test func screenshotKeysMustBeCombinationsNotHolds() {
        #expect(SettingsRules.keyProblem(.shot, text: "shift", in: Settings())?.contains("長押し") == true)
        #expect(SettingsRules.keyProblem(.shot, text: "ctrl+opt+s", in: Settings()) == nil)
    }

    @Test func emptyMeansUnusedOrDefaultAndNeverAProblemByItself() {
        #expect(SettingsRules.keyProblem(.chat, text: "  ", in: Settings()) == nil)
        #expect(SettingsRules.keyProblem(.listen, text: "", in: Settings()) == nil)
    }

    @Test func theSendKeyOnlyNeedsAReadableStrokeAndNeverClashesWithTriggers() {
        var settings = Settings()
        settings.hotkey = "cmd+return"   // 同じ組み合わせのトリガーがあっても、1 回押すキーは、重なりを見ない
        #expect(SettingsRules.keyProblem(.sendKey(0), text: "cmd+return", in: settings) == nil)
        #expect(SettingsRules.keyProblem(.sendKey(0), text: "return", in: settings) == nil)            // 単独も、よい
        #expect(SettingsRules.keyProblem(.sendKey(0), text: "", in: settings) == nil)                   // 空は、問題ではない（外す）
        #expect(SettingsRules.keyProblem(.sendKey(0), text: "cmd", in: settings) != nil)                // 修飾キーだけは、読めない
        #expect(SettingsRules.keyProblem(.sendKey(0), text: "enterr", in: settings) != nil)
    }

    @Test func theSendKeyListIsEditedByPositionAndTheLegacyKeyIsDroppedOnTheFirstWrite() {
        var settings = Settings(); settings.dictateKey = "cmd+return"
        KeyKind.sendKey(1).set("tab", in: &settings)                       // 一覧の末尾の次：足す（古い 1 つが、先頭に残る）
        #expect(settings.dictateKeys == ["cmd+return", "tab"] && settings.dictateKey == nil)
        KeyKind.sendKey(0).set("return", in: &settings)                    // 置き換える
        KeyKind.sendKey(1).set(nil, in: &settings)                         // 外す
        #expect(settings.dictateKeys == ["return"])
        KeyKind.sendKey(0).set("", in: &settings)
        #expect(settings.dictateKeys == [] && settings.dictateSend.modes.count == 1)   // 空にしても、Enter に戻らない
        KeyKind.sendKey(5).set(nil, in: &settings)                         // 範囲外の取り外しは、何もしない
        #expect(settings.dictateKeys == [])
    }

    /// 文字起こしの開始・停止のキー（F80）は、音声入力のキーとは別：組み合わせだけ・ほかのキーと重ならない・設定に、別々に書く。
    @Test func theTranscribeShortcutIsSeparateFromDictationAndNeedsAFreeCombination() {
        var settings = Settings()
        settings.dictateHotkey = "ctrl"
        #expect(SettingsRules.keyProblem(.transcribe, text: "ctrl+opt+t", in: settings) == nil)
        #expect(SettingsRules.keyProblem(.transcribe, text: "shift", in: settings) != nil)             // 長押しは、使えない（組み合わせだけ）
        settings.shotHotkey = "ctrl+opt+t"
        #expect(SettingsRules.keyProblem(.transcribe, text: "ctrl+opt+t", in: settings) != nil)        // 画面撮影と、重なる
        KeyKind.transcribe.set("ctrl+opt+y", in: &settings)
        #expect(settings.transcribeHotkey == "ctrl+opt+y" && settings.dictateHotkey == "ctrl")        // 音声入力のキーは、そのまま
        KeyKind.transcribe.set(nil, in: &settings)
        #expect(settings.transcribeHotkey == nil)
    }

    /// 自分の声の文字起こしのキーは、相手の音声のキーとも別：別々に書け、重なれば断る。
    @Test func theTranscribeKeysForTheOtherPartyAndForMyVoiceAreIndependentAndMayNotClash() {
        var settings = Settings()
        KeyKind.transcribe.set("ctrl+opt+t", in: &settings)
        KeyKind.transcribeMic.set("ctrl+opt+m", in: &settings)
        #expect(settings.transcribeHotkey == "ctrl+opt+t" && settings.transcribeMicHotkey == "ctrl+opt+m")
        #expect(SettingsRules.keyProblem(.transcribeMic, text: "ctrl+opt+t", in: settings) != nil)     // 相手の音声のキーと、重なる
        #expect(SettingsRules.keyProblem(.transcribeMic, text: "shift", in: settings) != nil)          // 長押しは、使えない
        KeyKind.transcribeMic.set(nil, in: &settings)
        #expect(settings.transcribeHotkey == "ctrl+opt+t" && settings.transcribeMicHotkey == nil)
    }
}

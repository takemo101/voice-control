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

    @Test func enginesRoundTripAndLocalOnlyIsEnforced() {
        #expect(SettingsRules.splitEngine(nil) == (.apple, ""))
        #expect(SettingsRules.splitEngine("ollama:qwen3.5:4b") == (.ollama, "qwen3.5:4b"))
        #expect(SettingsRules.splitEngine("openai:model@8080") == (.openai, "model@8080"))
        #expect(SettingsRules.engineText(kind: .ollama, rest: " qwen3.5:4b ") == "ollama:qwen3.5:4b")
        #expect(SettingsRules.engineText(kind: .apple, rest: "ignored") == "apple")
        #expect(SettingsRules.engineProblem(kind: .apple, rest: "") == nil)
        #expect(SettingsRules.engineProblem(kind: .ollama, rest: "qwen3.5:4b") == nil)
        #expect(SettingsRules.engineProblem(kind: .ollama, rest: "  ") == "モデルの名前を入れてください")
        #expect(SettingsRules.engineProblem(kind: .openai, rest: "no-port") != nil)   // ポートがない
    }

    @Test func theSendKeyOnlyNeedsAReadableStrokeAndNeverClashesWithTriggers() {
        var settings = Settings()
        settings.hotkey = "cmd+return"   // 同じ組み合わせのトリガーがあっても、1 回押すキーは、重なりを見ない
        #expect(SettingsRules.keyProblem(.sendKey(0), text: "cmd+return", in: settings) == nil)
        #expect(SettingsRules.keyProblem(.sendKey(0), text: "return", in: settings) == nil)            // 単独も、よい
        #expect(SettingsRules.keyProblem(.sendKey(0), text: "", in: settings) == nil)                   // 空は、問題ではない（外す）
        #expect(SettingsRules.keyProblem(.sendKey(0), text: "cmd", in: settings) != nil)                // 修飾キーだけは、読めない
        #expect(SettingsRules.keyProblem(.sendKey(0), text: "enterr", in: settings) != nil)
        #expect(KeyKind.triggers == [.listen, .dictate, .chat, .shot])
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
}


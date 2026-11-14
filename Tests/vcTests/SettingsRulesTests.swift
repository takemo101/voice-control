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
}

import Testing
import VCSkill
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

    /// OpenAI 互換の入力欄は、モデルの名前とエンドポイントの 2 つ。貼り付けた URL（`http://…/v1`）も、受ける。
    @Test func theOpenAIEndpointIsAPastedUrlOrAHostAndPortAndHttpsIsRefused() {
        #expect(SettingsRules.splitOpenAI("qwen@192.168.1.5:8080") == ("qwen", "192.168.1.5:8080") && SettingsRules.splitOpenAI("org/m:q4@8000") == ("org/m:q4", "8000"))
        #expect(SettingsRules.splitOpenAI("only-model") == ("only-model", ""))
        for (input, expected) in [("8000", "8000"), (" 127.0.0.1:8000 ", "127.0.0.1:8000"), ("http://192.168.1.5:8080", "192.168.1.5:8080"), ("http://192.168.1.5:8080/v1", "192.168.1.5:8080/v1"),
                                  ("HTTP://Box.local:8000/v2/", "Box.local:8000/v2"), ("http://127.0.0.1:8000/", "127.0.0.1:8000"), ("http://box.local/openai/v1", "box.local:80/openai/v1"), ("http://192.168.1.5", "192.168.1.5:80")] {
            #expect(SettingsRules.normalizeEndpoint(input) == (expected, nil), "\(input)")
        }
        #expect(SettingsRules.normalizeEndpoint("https://192.168.1.5:8080").problem != nil)
        #expect(SettingsRules.modelRest(kind: .openai, model: " qwen3-4b ", endpoint: "http://192.168.1.5:8080/v1") == "qwen3-4b@192.168.1.5:8080/v1")
        // Ollama は、エンドポイントを省ける（省くと、`<モデル>` だけ：既定の場所）
        #expect(SettingsRules.modelRest(kind: .ollama, model: "qwen3.5:4b", endpoint: "") == "qwen3.5:4b")
        #expect(SettingsRules.modelRest(kind: .ollama, model: "qwen3.5:4b", endpoint: "192.168.1.5:11434") == "qwen3.5:4b@192.168.1.5:11434")
        #expect(SettingsRules.engineProblem(kind: .ollama, rest: "qwen3.5:4b") == nil && SettingsRules.engineProblem(kind: .ollama, rest: "qwen3.5:4b@192.168.1.5:11434") == nil)
        #expect(SettingsRules.engineProblem(kind: .ollama, rest: "@11434") == "モデルの名前を入れてください")
        #expect(SettingsRules.engineServer(kind: .ollama, rest: "qwen3.5:4b") == Engine.ollamaDefault)               // 省くと、既定
        #expect(SettingsRules.engineServer(kind: .ollama, rest: "m@192.168.1.5:11434")?.endpoint == "192.168.1.5:11434")
        #expect(SettingsRules.engineProblem(kind: .openai, rest: "qwen3-4b@192.168.1.5:8080") == nil)
        #expect(SettingsRules.engineProblem(kind: .openai, rest: "qwen3-4b@") == "エンドポイントを入れてください（例：8000・192.168.1.5:8080）")   // 途中の入力は、問題として見せる（保存しない）
        #expect(SettingsRules.engineProblem(kind: .openai, rest: "@8000") == "モデルの名前を入れてください")
        #expect(SettingsRules.engineProblem(kind: .openai, rest: "m@8.8.8.8:80") != nil)                              // 公開の場所は、拒否
    }

    /// 許可していない LAN のサーバーは、保存しない（保存すると、再読み込みが「許可していません」の失敗になる）。許可は、場所ごと。
    @Test func aLANEngineIsPersistedOnlyOnceThatPlaceIsApproved() {
        #expect(SettingsRules.persistedEngine(kind: .openai, rest: "m@192.168.1.5:8080", approved: nil) == nil)
        #expect(SettingsRules.persistedEngine(kind: .openai, rest: "m@192.168.1.5:8080", approved: "192.168.1.6:8080") == nil)   // 別の場所の許可は、効かない
        #expect(SettingsRules.persistedEngine(kind: .openai, rest: "m@192.168.1.5:8080/v2", approved: "192.168.1.5:8080") == "openai:m@192.168.1.5:8080/v2")   // 経路が違っても、同じ場所
        #expect(SettingsRules.persistedEngine(kind: .ollama, rest: "m@box.local:11434", approved: "BOX.local:11434") == "ollama:m@box.local:11434")
        #expect(SettingsRules.persistedEngine(kind: .openai, rest: "m@8000", approved: nil) == "openai:m@8000")                     // この Mac は、許可が要らない
        #expect(SettingsRules.persistedEngine(kind: .ollama, rest: "qwen3.5:4b", approved: nil) == "ollama:qwen3.5:4b")
        #expect(SettingsRules.persistedEngine(kind: .apple, rest: "", approved: nil) == nil)
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


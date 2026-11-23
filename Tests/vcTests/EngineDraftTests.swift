import Testing
import VCCore
import VCSkill
@testable import vc

/// エンジンの入力（設定ウィンドウ）：文字の規則と、状態の移り変わり。**設定ファイルへは、書かない**（`EngineDraft` は、画面・保存から分けてある）。
@Suite struct EngineDraftTests {
    private func settings(engine: String? = nil, rests: [String: String]? = nil, approved: String? = nil) -> Settings {
        var settings = Settings(); settings.engine = engine; settings.engineRests = rests; settings.engineApproved = approved
        return settings
    }

    // MARK: 文字の規則

    @Test func enginesRoundTripAndEachKindHasItsOwnRules() {
        #expect(EngineRules.splitEngine(nil) == (.apple, ""))
        #expect(EngineRules.splitEngine("ollama:qwen3.5:4b") == (.ollama, "qwen3.5:4b"))
        #expect(EngineRules.splitEngine("openai:model@8080") == (.openai, "model@8080"))
        #expect(EngineRules.engineText(kind: .ollama, rest: " qwen3.5:4b ") == "ollama:qwen3.5:4b")
        #expect(EngineRules.engineText(kind: .apple, rest: "ignored") == "apple")
        #expect(EngineRules.problem(kind: .apple, rest: "") == nil)
        #expect(EngineRules.problem(kind: .ollama, rest: "qwen3.5:4b") == nil)
        #expect(EngineRules.problem(kind: .ollama, rest: "  ") == "モデルの名前を入れてください")
        #expect(EngineRules.problem(kind: .openai, rest: "no-port") != nil)   // 場所がない
    }

    @Test func theModelAndTheEndpointAreSplitAndJoinedAndOllamaMayOmitTheEndpoint() {
        #expect(EngineRules.splitModelEndpoint("qwen@192.168.1.5:8080") == ("qwen", "192.168.1.5:8080") && EngineRules.splitModelEndpoint("org/m:q4@8000") == ("org/m:q4", "8000"))
        #expect(EngineRules.splitModelEndpoint("only-model") == ("only-model", ""))
        #expect(EngineRules.modelRest(kind: .openai, model: " qwen3-4b ", endpoint: "http://192.168.1.5:8080/v1") == "qwen3-4b@192.168.1.5:8080/v1")
        #expect(EngineRules.modelRest(kind: .ollama, model: "qwen3.5:4b", endpoint: "") == "qwen3.5:4b")                                    // Ollama：省くと、既定の場所
        #expect(EngineRules.modelRest(kind: .ollama, model: "qwen3.5:4b", endpoint: "192.168.1.5:11434") == "qwen3.5:4b@192.168.1.5:11434")
        #expect(EngineRules.problem(kind: .openai, rest: "qwen3-4b@") == "エンドポイントを入れてください（例：8000・192.168.1.5:8080）")   // 途中の入力は、問題として見せる
        #expect(EngineRules.problem(kind: .openai, rest: "@8000") == "モデルの名前を入れてください" && EngineRules.problem(kind: .ollama, rest: "@11434") == "モデルの名前を入れてください")
        #expect(EngineRules.problem(kind: .openai, rest: "m@8.8.8.8:80") != nil)                                                          // 公開の場所は、拒否
        #expect(EngineRules.server(kind: .ollama, rest: "qwen3.5:4b") == ModelServerKind.ollama.defaultAddress)                           // 省くと、既定
        #expect(EngineRules.server(kind: .ollama, rest: "m@192.168.1.5:11434")?.endpoint == "192.168.1.5:11434")
    }

    /// 許可していない LAN のサーバーは、保存しない（保存すると、再読み込みが「許可していません」の失敗になる）。許可は、場所ごと。
    @Test func aLANEngineIsPersistedOnlyOnceThatPlaceIsApproved() {
        #expect(EngineRules.persistedEngine(kind: .openai, rest: "m@192.168.1.5:8080", approved: nil) == nil)
        #expect(EngineRules.persistedEngine(kind: .openai, rest: "m@192.168.1.5:8080", approved: "192.168.1.6:8080") == nil)   // 別の場所の許可は、効かない
        #expect(EngineRules.persistedEngine(kind: .openai, rest: "m@192.168.1.5:8080/v2", approved: "192.168.1.5:8080") == "openai:m@192.168.1.5:8080/v2")   // 経路が違っても、同じ場所
        #expect(EngineRules.persistedEngine(kind: .ollama, rest: "m@box.local:11434", approved: "BOX.local:11434") == "ollama:m@box.local:11434")
        #expect(EngineRules.persistedEngine(kind: .openai, rest: "m@8000", approved: nil) == "openai:m@8000")                     // この Mac は、許可が要らない
        #expect(EngineRules.persistedEngine(kind: .ollama, rest: "qwen3.5:4b", approved: nil) == "ollama:qwen3.5:4b")
        #expect(EngineRules.persistedEngine(kind: .apple, rest: "", approved: nil) == nil)
    }

    @Test func eachEngineKeepsItsOwnInputWhenYouSwitchBetweenThem() {
        let remembered = ["ollama": "qwen3.5:4b@192.168.1.5:11434", "openai": "inkling@8000/v2"]
        #expect(EngineRules.rest(for: .ollama, engine: "openai:m@8000", remembered: remembered) == "qwen3.5:4b@192.168.1.5:11434")   // 使っているのは OpenAI：Ollama は、覚えていた入力
        #expect(EngineRules.rest(for: .openai, engine: "openai:m@8000", remembered: remembered) == "m@8000")                          // 使っている種類は、その設定
        #expect(EngineRules.rest(for: .openai, engine: "ollama:q", remembered: remembered) == "inkling@8000/v2")
        #expect(EngineRules.rest(for: .openai, engine: nil, remembered: nil) == "" && EngineRules.rest(for: .ollama, engine: "openai:m@8000", remembered: [:]) == "")   // 覚えていなければ、空
        #expect(EngineRules.rest(for: .apple, engine: "openai:m@8000", remembered: remembered) == "")
    }

    // MARK: 状態の移り変わり（`EngineDraft`）

    @Test func switchingKindsKeepsEachInputSeparateEvenWhenItIsHalfTyped() {
        var draft = EngineDraft(settings: settings(engine: "openai:inkling@http://192.168.1.5:8080/v1".replacingOccurrences(of: "http://", with: "")))
        #expect(draft.kind == .openai && draft.model == "inkling" && draft.endpoint == "192.168.1.5:8080/v1")
        draft.switchKind(.ollama, settings: settings(engine: "openai:inkling@192.168.1.5:8080/v1"))
        #expect(draft.kind == .ollama && draft.model == "" && draft.endpoint == "" && draft.problem == nil)       // 何も入れていない種類：OpenAI の入力は、混ざらない。問題も、出さない
        draft.edit(model: "qwen3.5:4b")
        #expect(draft.problem == nil && draft.isComplete && draft.rest == "qwen3.5:4b")
        draft.edit(endpoint: "http://192.168.1.9:11434")
        #expect(draft.rest == "qwen3.5:4b@192.168.1.9:11434" && draft.endpoint == "http://192.168.1.9:11434")    // 入力欄は、貼ったままの形
        draft.switchKind(.openai, settings: settings(engine: "ollama:qwen3.5:4b@192.168.1.9:11434"))
        #expect(draft.model == "inkling" && draft.endpoint == "192.168.1.5:8080/v1")                               // OpenAI に戻ると、覚えていた入力
        draft.edit(endpoint: "http://")                                                                           // 途中の入力
        #expect(draft.problem != nil && !draft.isComplete)
        draft.switchKind(.ollama, settings: settings())
        #expect(draft.model == "qwen3.5:4b" && draft.endpoint == "http://192.168.1.9:11434".replacingOccurrences(of: "http://", with: ""))   // 戻ると、保存できた入力（途中の入力は、保存できる形ではない）
    }

    @Test func onlyACompleteApprovedInputBecomesTheStoredEngineAndOnlyValidInputsAreRemembered() {
        var draft = EngineDraft(settings: settings())
        draft.switchKind(.openai, settings: settings())
        #expect(draft.persistedEngine(approved: nil) == nil && draft.persistedRests(base: nil) == nil)           // 入力がない：Apple のまま。覚えるものも、ない
        draft.edit(model: "m", endpoint: "192.168.1.5:8080")
        #expect(draft.isComplete && draft.persistedEngine(approved: nil) == nil)                                  // LAN：許可がなければ、保存しない
        #expect(draft.persistedEngine(approved: "192.168.1.5:8080") == "openai:m@192.168.1.5:8080")
        #expect(draft.persistedRests(base: ["ollama": "q"]) == ["ollama": "q", "openai": "m@192.168.1.5:8080"])   // 覚えた入力は、許可に関わらず、残る。ほかの種類は、そのまま
        draft.edit(endpoint: "https://192.168.1.5:8080")
        #expect(draft.problem == Engine.ParseError.invalidScheme("https").description && draft.persistedEngine(approved: "192.168.1.5:8080") == nil)   // https：理由を出して、保存しない
        #expect(draft.persistedRests(base: nil) == ["openai": "m@192.168.1.5:8080"])                              // 書き方が正しくなかった入力は、覚えた入力を、上書きしない
        draft.edit(endpoint: "8000")
        #expect(draft.persistedEngine(approved: nil) == "openai:m@8000" && draft.server == .loopback(port: 8000))   // この Mac は、許可が要らない
    }
}

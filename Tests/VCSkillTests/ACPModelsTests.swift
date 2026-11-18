import Foundation
import Testing
@testable import VCSkill

/// モデルの一覧（エージェントが返す）の読み方と、選ぶ要求。**実際のエージェントが返した形**で。
@Suite struct ACPModelsTests {
    private func json(_ text: String) -> JSONValue {
        guard let value = JSONValue.parse(Data(text.utf8)) else { Issue.record("JSON を読めない"); return .null }
        return value
    }

    @Test func aModelsListFromTheAgentIsReadWithNamesDescriptionsAndTheCurrentOne() {
        // agy・Codex・Grok の形（`models.availableModels`）
        let parsed = ACPModels.parse(json(#"{"sessionId":"s","models":{"currentModelId":"gpt-6.1-sol[low]","availableModels":[{"modelId":"gpt-6.1-sol[low]","name":"GPT 6.1 low","description":"速い"},{"modelId":"gpt-6.1-sol[high]"},{"name":"idなし"}]}}"#))
        #expect(parsed.listing.choices.map(\.id) == ["gpt-6.1-sol[low]", "gpt-6.1-sol[high]"])           // 番号のないものは、捨てる
        #expect(parsed.listing.choices[0].name == "GPT 6.1 low" && parsed.listing.choices[0].detail == "速い")
        #expect(parsed.listing.choices[1].name == "gpt-6.1-sol[high]" && parsed.listing.choices[1].detail == nil)   // 名前がなければ、値
        #expect(parsed.listing.current == "gpt-6.1-sol[low]" && parsed.configID == nil)
    }

    @Test func aModelOptionInConfigOptionsIsReadFlatOrGroupedWhenThereIsNoModelsList() {
        // Claude のアダプターの形（`configOptions` の `model`）。`group` ごとの一覧も、平らにする
        let parsed = ACPModels.parse(json(#"{"sessionId":"s","configOptions":[{"id":"mode","category":"mode","currentValue":"auto","options":[{"value":"default"}]},{"id":"model","category":"model","currentValue":"haiku","options":[{"value":"haiku","name":"Haiku"},{"group":"big","name":"Big","options":[{"value":"sonnet","name":"Sonnet"},{"value":"opus"}]}]}]}"#))
        #expect(parsed.listing.choices.map(\.id) == ["haiku", "sonnet", "opus"] && parsed.listing.current == "haiku")
        #expect(parsed.configID == "model")                                                          // `mode` の選択肢は、モデルではない
    }

    @Test func nothingIsListedWhenTheAgentReturnsNoModels() {
        #expect(ACPModels.parse(json(#"{"sessionId":"s"}"#)).listing.choices.isEmpty)
        #expect(ACPModels.parse(json(#"{"sessionId":"s","models":{"availableModels":[]},"configOptions":[]}"#)).listing.choices.isEmpty)
    }

    @Test func aModelIsChosenThroughTheWayTheAgentOffersItAndOnlyIfItIsInTheList() {
        let list = ACPModels.parse(json(#"{"models":{"availableModels":[{"modelId":"m1"}]}}"#))
        let viaModel = ACPModels.request(for: "m1", parsed: list, sessionID: "s1")
        #expect(viaModel?.method == "session/set_model" && viaModel?.params["modelId"]?.string == "m1" && viaModel?.params["sessionId"]?.string == "s1")
        #expect(ACPModels.request(for: "stale", parsed: list, sessionID: "s1") == nil)               // 一覧にない値は、渡さない
        let config = ACPModels.parse(json(#"{"configOptions":[{"id":"model","options":[{"value":"haiku"}]}]}"#))
        let viaOption = ACPModels.request(for: "haiku", parsed: config, sessionID: "s2")
        #expect(viaOption?.method == "session/set_config_option" && viaOption?.params["configId"]?.string == "model" && viaOption?.params["value"]?.string == "haiku")
    }
}

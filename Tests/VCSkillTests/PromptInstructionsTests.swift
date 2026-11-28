import Testing
@testable import VCSkill

/// 指示（整え方・まとめ方）の、設定との行き来：既定と同じ・空の文は、設定に残さない（既定が更新されたとき、追いつく）。
@Suite struct PromptInstructionsTests {
    @Test func aBlankOrDefaultTextIsNotKeptInTheSetting() {
        #expect(PromptInstructions.setting(from: " \n ", default: "既定", maxLength: 10) == nil)
        #expect(PromptInstructions.setting(from: "  既定  ", default: "既定", maxLength: 10) == nil)
        #expect(PromptInstructions.setting(from: "  口調はそのまま  ", default: "既定", maxLength: 10) == "口調はそのまま")
    }

    @Test func aLongTextIsCutOnTheWayInAndOut() {
        let long = String(repeating: "あ", count: 50)
        #expect(PromptInstructions.setting(from: long, default: "既定", maxLength: 10)?.count == 10)
        #expect(PromptInstructions.resolve(setting: long, default: "既定", maxLength: 10).count == 10)
        #expect(PromptInstructions.resolve(setting: nil, default: "既定", maxLength: 10) == "既定")
    }
}

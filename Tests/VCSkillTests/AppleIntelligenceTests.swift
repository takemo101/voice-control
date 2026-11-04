import FoundationModels
import Testing
@testable import VCSkill

@Suite struct AppleIntelligenceTests {
    @Test func theSystemsAnswerMapsToAStatusWithTheRightReason() {
        #expect(AppleIntelligence.status(of: .available) == .available)
        #expect(AppleIntelligence.status(of: .unavailable(.deviceNotEligible)) == .unavailable(.deviceNotEligible))
        #expect(AppleIntelligence.status(of: .unavailable(.appleIntelligenceNotEnabled)) == .unavailable(.notEnabled))
        #expect(AppleIntelligence.status(of: .unavailable(.modelNotReady)) == .unavailable(.modelNotReady))
    }

    /// 使えない理由ごとに、利用者が次に何をするかが違う：オフなら「オンにする」、準備中なら「待つ」、非対応なら「この Mac では使えない」。
    @Test func eachReasonTellsTheUserWhatToDoNext() {
        #expect(AppleIntelligence.Reason.notEnabled.remedy.contains("オンにして"))
        #expect(AppleIntelligence.Reason.modelNotReady.remedy.contains("待って"))
        #expect(AppleIntelligence.Reason.deviceNotEligible.remedy.contains("使える Mac"))
        let reasons: [AppleIntelligence.Reason] = [.deviceNotEligible, .notEnabled, .modelNotReady, .unknown]
        #expect(Set(reasons.map(\.summary)).count == reasons.count)
        #expect(Set(reasons.map(\.remedy)).count == reasons.count)
    }
}

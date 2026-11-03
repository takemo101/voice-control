import Testing
@testable import VCDecision

@Suite struct GateTests {
    @Test func executesOnlyConfidentHarmlessSteps() {
        let gate = Gate()
        #expect(gate.verdict(stages: [0.95], destructive: 0.1, forceConfirm: false) == .execute)
        #expect(gate.verdict(stages: [0.95, 0.60], destructive: nil, forceConfirm: false) == .confirm)
        #expect(gate.verdict(stages: [0.95, 0.30], destructive: nil, forceConfirm: false) == .reject)
    }

    @Test func riskyOrForcedStepsAlwaysNeedConfirmation() {
        let gate = Gate()
        #expect(gate.verdict(stages: [0.999], destructive: 0.9, forceConfirm: false) == .confirm)
        #expect(gate.verdict(stages: [0.999], destructive: nil, forceConfirm: true) == .confirm)
        #expect(gate.verdict(stages: [0.30], destructive: 0.9, forceConfirm: true) == .reject)
    }
}

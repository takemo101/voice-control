import Foundation
import Testing
import TestSupport
@testable import VCDecision

@Suite struct ChooserTests {
    private let options = (0..<100).map { "option \($0)" }

    @Test func findsTheTargetAmongMoreCandidatesThanOneCallAccepts() throws {
        for target in [0, 30, 31, 62, 99] {
            let scorer = TargetScorer(target: "option \(target)")
            let pick = try Chooser(scorer: scorer, limit: 32).pick(state: "", question: "", options: options, none: "none")
            #expect(pick.index == target)
            #expect(scorer.widest <= 32)
        }
    }

    @Test func returnsNoneWhenNoCandidateMatches() throws {
        let scorer = TargetScorer(target: nil)
        let pick = try Chooser(scorer: scorer, limit: 32).pick(state: "", question: "", options: options, none: "none")
        #expect(pick.index == nil)
    }

    @Test func aListThatFitsInOneQuestionIsScoredOnce() throws {
        for count in [1, 31] {
            let scorer = TargetScorer(target: "option 0")
            let opts = (0..<count).map { "option \($0)" }
            _ = try Chooser(scorer: scorer, limit: 32).pick(state: "", question: "", options: opts, none: "none")
            #expect(scorer.calls == 1, "count \(count)")
        }
    }
}

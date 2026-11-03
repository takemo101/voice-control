import Foundation
import TestSupport
import Testing
import VCDecision
@testable import VCPCControl

/// 声の確認：「はい」と確信できたときだけ、実行を許す（聞き違い・迷いで、確認が必要な操作が実行されない）。
@Suite struct ConfirmationTests {
    /// 「はい」「いいえ」「どちらでもない」の確率を、そのまま返す。
    private struct Probabilities: OptionScorer {
        let yes: Double, no: Double, neither: Double
        func score(state: String, question: String, options: [String]) throws -> [Double] { [yes, no, neither] }
    }

    @Test func aConfidentYesApproves() throws {
        #expect(try Confirmation(scorer: TargetScorer(target: "はい（実行してよい）")).isYes("はい"))
    }

    @Test func noOrNeitherDoesNotApprove() throws {
        #expect(try !Confirmation(scorer: TargetScorer(target: "いいえ（やめる）")).isYes("いいえ"))
        #expect(try !Confirmation(scorer: TargetScorer(target: nil)).isYes("えーと"))   // 「どちらでもない」
    }

    @Test func aHesitantYesDoesNotApprove() throws {
        #expect(try !Confirmation(scorer: Probabilities(yes: 0.6, no: 0.3, neither: 0.1)).isYes("はい"))   // 最有力でも、確信（0.8）に届かない
        #expect(try Confirmation(scorer: Probabilities(yes: 0.85, no: 0.1, neither: 0.05)).isYes("はい"))
    }
}

import Foundation
import Testing
import TestSupport
@testable import VCDecision

/// 声の確認：「はい」と確信できたときだけ、実行を許す（聞き違い・迷いで、確認が必要な操作が実行されない）。
@Suite struct ConfirmationTests {
    /// 「はい」「いいえ」「どちらでもない」の確率を、そのまま返す。
    private struct Probabilities: OptionScorer {
        let yes: Double, no: Double, neither: Double
        func score(state: String, question: String, options: [String]) throws -> [Double] { [yes, no, neither] }
    }

    @Test func aConfidentYesApproves() throws {
        #expect(try Confirmation(scorer: TargetScorer(target: "はい（実行してよい）")).isYes("ええと、はい、それでお願いします"))   // 決まった言い方でない文は、Tiny-Jev が決める
    }

    @Test func noOrNeitherDoesNotApprove() throws {
        #expect(try !Confirmation(scorer: TargetScorer(target: "いいえ（やめる）")).isYes("いいえ"))
        #expect(try !Confirmation(scorer: TargetScorer(target: nil)).isYes("えーと"))   // 「どちらでもない」
    }

    @Test func aHesitantYesDoesNotApprove() throws {
        #expect(try !Confirmation(scorer: Probabilities(yes: 0.6, no: 0.3, neither: 0.1)).isYes("たぶん、はい"))   // 最有力でも、確信（0.8）に届かない
        #expect(try Confirmation(scorer: Probabilities(yes: 0.85, no: 0.1, neither: 0.05)).isYes("たぶん、はい"))
    }

    /// 決まった言い方は、Tiny-Jev の自信に関わらず、はい（測定：「はい」が 0.64 で、通らなかった）。
    @Test func aPlainYesIsApprovedEvenWhenTheModelIsUnsure() throws {
        let unsure = Confirmation(scorer: Probabilities(yes: 0.4, no: 0.3, neither: 0.3))
        for reply in ["はい", "はい。", "はい、お願いします", "ハイ！", "お願いします", "実行してください", "OK", "ＯＫ", "了解です"] {
            #expect(try unsure.isYes(reply), "\(reply)")
        }
    }

    /// 関係のない発言・断り・「はい」のあとの取り消しは、決まった言い方ではないので、Tiny-Jev にかけ、確信がなければ、はいにしない。
    @Test func talkThatIsNotAPlainYesIsNotApprovedByTheRule() throws {
        let unsure = Confirmation(scorer: Probabilities(yes: 0.4, no: 0.3, neither: 0.3))
        for reply in ["ありがとう", "そうなんだ", "いいえ", "はい、やっぱりやめて", "はいはい、ちょっと待って", "いいです", "大丈夫です", "", "。"] {
            #expect(try !unsure.isYes(reply), "\(reply)")
        }
    }
}

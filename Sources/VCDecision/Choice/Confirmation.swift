import Foundation

/// 確認への、声の返事。**はい と確信できたときだけ true**。
/// 1. 決まった言い方（「はい」「お願いします」「実行して」…。`affirmatives`）だけでできた返事は、はい。
/// 2. それ以外は、Tiny-Jev で、はい／いいえ／どちらでもない を選び、確信度が高いときだけ、はい。
/// 1 を足した理由（測定。2026-11-05）：Tiny-Jev だけでは、「はい」が 0.64、「はい。」が 0.43 で、`yesThreshold`（0.8）に届かず、**「はい」と言っても確認が通らなかった**
/// （16 の肯定の言い方のうち、通ったのは 3）。確認の文脈を足した言い方に変えると、肯定は全部通ったが、「ありがとう」「そうなんだ」まで 1.00 で、はいになった（関係のない発言で、実行してしまう）。
/// 決まった言い方の一致なら、関係のない発言は、通らない。
public struct Confirmation: Sendable {
    public static let yesThreshold = 0.8
    private let chooser: Chooser
    public init(scorer: OptionScorer) { chooser = Chooser(scorer: scorer) }

    public func isYes(_ utterance: String) throws -> Bool {
        if Self.isAffirmative(utterance) { return true }
        let pick = try chooser.pick(
            state: utterance, question: "この返事は、操作の実行を許可しているか",
            options: ["はい（実行してよい）", "いいえ（やめる）"], none: "どちらでもない")
        return pick.index == 0 && pick.probability >= Self.yesThreshold
    }

    /// 実行してよい、という決まった言い方。「いいです」「大丈夫です」は、「結構です（断り）」の意味にもなるので、含めない。
    static let affirmatives: Set<String> = [
        "はい", "ハイ", "ええ", "うん", "お願いします", "お願い", "おねがいします", "実行して", "実行してください", "やって", "やってください", "やってくれ",
        "いいよ", "いいですよ", "どうぞ", "ok", "オーケー", "オッケー", "了解", "了解です", "承知", "進めて", "進めてください", "続けて", "続けてください",
    ]

    /// 返事が、決まった言い方だけでできているか。「はい、お願いします」のように、読点・空白で区切った、どの部分も、決まった言い方であること
    /// （「はい、やっぱりやめて」は、後ろが決まった言い方でないので、はいにしない）。
    static func isAffirmative(_ utterance: String) -> Bool {
        let folded = utterance.precomposedStringWithCompatibilityMapping.lowercased()
        let separators = CharacterSet(charactersIn: "、，,。．.！!？?〜~…").union(.whitespacesAndNewlines)
        let parts = folded.components(separatedBy: separators).filter { !$0.isEmpty }
        return !parts.isEmpty && parts.allSatisfy { affirmatives.contains($0) }
    }
}

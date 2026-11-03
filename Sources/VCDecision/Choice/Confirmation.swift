import Foundation

/// 確認への、声の返事。Tiny-Jev で、はい／いいえ／どちらでもない を選ぶ。**はい と確信できたときだけ true**。
public struct Confirmation: Sendable {
    public static let yesThreshold = 0.8
    private let chooser: Chooser
    public init(scorer: OptionScorer) { chooser = Chooser(scorer: scorer) }

    public func isYes(_ utterance: String) throws -> Bool {
        let pick = try chooser.pick(
            state: utterance, question: "この返事は、操作の実行を許可しているか",
            options: ["はい（実行してよい）", "いいえ（やめる）"], none: "どちらでもない")
        return pick.index == 0 && pick.probability >= Self.yesThreshold
    }
}

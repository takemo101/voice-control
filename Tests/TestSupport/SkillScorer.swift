import Foundation
import VCDecision

/// 質問ごとに、決めた確率を返す偽物（スキルの選択・操作の依頼か・取り消しにくいか）。`fails` なら、どの質問にも失敗する。
public struct SkillScorer: OptionScorer {
    /// スキルの選択で、勝たせる選択肢（説明の文字列）。`nil` なら「どれでもない」（最後の選択肢）。
    public var routedDescription: String?
    public var actionable: Double
    public var destructive: Double
    public var fails: Bool

    public struct Broken: Error {}

    public init(routedDescription: String? = nil, actionable: Double = 0.9, destructive: Double = 0.1, fails: Bool = false) {
        self.routedDescription = routedDescription
        self.actionable = actionable
        self.destructive = destructive
        self.fails = fails
    }

    public func score(state: String, question: String, options: [String]) throws -> [Double] {
        if fails { throw Broken() }
        if question.hasPrefix("この発話は、どちらか") { return [1 - actionable, actionable] }
        if question.hasPrefix("この依頼は、削除") { return [1 - destructive, destructive] }
        var p = options.map { _ in 0.01 }
        p[routedDescription.flatMap { options.firstIndex(of: $0) } ?? options.count - 1] = 0.9
        let sum = p.reduce(0, +)
        return p.map { $0 / sum }
    }
}

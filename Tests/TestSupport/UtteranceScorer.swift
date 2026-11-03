import Foundation
import VCDecision

/// 発話ごとに、選ぶ選択肢と確率を決めておく偽物（PC 操作の `Planner` 用。決めていない発話は、会話＝「どれでもない」）。取り消しにくさの問い（no／yes）には、`risk`。
public struct UtteranceScorer: OptionScorer {
    public let picks: [String: (option: String, p: Double)]
    public var risk: Double

    public init(picks: [String: (option: String, p: Double)], risk: Double = 0.0) {
        self.picks = picks
        self.risk = risk
    }

    public func score(state: String, question: String, options: [String]) throws -> [Double] {
        if options == ["no", "yes"] { return [1 - risk, risk] }
        let utterance = state.split(separator: "\n").last.map(String.init) ?? state
        var p = options.map { _ in 0.001 }
        if let pick = picks[utterance], let i = options.firstIndex(of: pick.option) { p[i] = pick.p } else { p[options.count - 1] = 0.9 }
        let sum = p.reduce(0, +)
        return p.map { $0 / sum }
    }
}

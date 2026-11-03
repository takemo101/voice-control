import Foundation

/// 選択肢に確率を返すもの。実機は `TinyJev`。テストは、決まった答えを返す偽物。
public protocol OptionScorer: Sendable {
    /// `options` ごとの確率（合計 1）。`options.count` は `TinyJev.maxOptions` 以下。
    func score(state: String, question: String, options: [String]) throws -> [Double]
}

extension TinyJev: OptionScorer {
    public func score(state: String, question: String, options: [String]) throws -> [Double] {
        try choose(state: state, question: question, options: options)
    }
}

/// 1 回の判断で入る選択肢の数（Tiny-Jev の上限）を超える候補を、勝ち抜き戦で選ぶ。
/// 候補を 1 組あたり `limit - 1` 個に分け、組ごとに「該当なし」を加えて採点し、各組の勝者だけで、また採点する。
public struct Chooser: Sendable {
    public struct Pick: Sendable {
        /// 勝った候補の添字。`nil` は「該当なし」。
        public let index: Int?
        /// 最後の採点での確率。**勝ち抜き戦では、勝者どうしの中での確率なので、1 回で決まる場合より楽観的**。
        public let probability: Double
        /// 最後の採点の順位（確率の降順。`nil` は「該当なし」）。
        public let ranked: [(index: Int?, probability: Double)]
    }

    private let scorer: OptionScorer
    private let limit: Int
    public init(scorer: OptionScorer, limit: Int = TinyJev.maxOptions) {
        precondition(limit >= 3)
        self.scorer = scorer
        self.limit = limit
    }

    /// 採点の回数の上限（候補が `limit - 1` 個以下なら 1 回。ある組が「該当なし」で勝ち残りなしなら、実際の回数は少ない）。
    public func rounds(for count: Int) -> Int {
        var n = count, total = 0
        while n > limit - 1 {
            total += (n + limit - 2) / (limit - 1)
            n = (n + limit - 2) / (limit - 1)
        }
        return total + 1
    }

    public func pick(state: String, question: String, options: [String], none: String) throws -> Pick {
        guard !options.isEmpty else { return Pick(index: nil, probability: 1, ranked: [(nil, 1)]) }
        var survivors = Array(options.indices)
        let width = limit - 1
        while survivors.count > width {
            var next: [Int] = []
            for start in stride(from: 0, to: survivors.count, by: width) {
                let group = Array(survivors[start..<min(start + width, survivors.count)])
                let p = try scorer.score(state: state, question: question, options: group.map { options[$0] } + [none])
                if let best = p.indices.max(by: { p[$0] < p[$1] }), best < group.count { next.append(group[best]) }
            }
            if next.isEmpty { return Pick(index: nil, probability: 1, ranked: [(nil, 1)]) }   // どの組でも「該当なし」
            survivors = next
        }
        let p = try scorer.score(state: state, question: question, options: survivors.map { options[$0] } + [none])
        let ranked = p.indices.map { (index: $0 < survivors.count ? survivors[$0] : Int?.none, probability: p[$0]) }.sorted { $0.probability > $1.probability }
        return Pick(index: ranked[0].index, probability: ranked[0].probability, ranked: ranked)
    }
}

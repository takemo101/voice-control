import Foundation
import VCDecision

/// 決めた 1 つの選択肢に確率を寄せる偽物（`target` が選択肢になければ、最後＝「該当なし」へ）。呼ばれた回数と、1 回の選択肢の最大数を記録する。
public final class TargetScorer: OptionScorer, @unchecked Sendable {
    public let target: String?
    private let others: Double
    private let lock = NSLock()
    private var callCount = 0
    private var widestCount = 0

    /// `others`：選ばれなかった選択肢の、確率の元（選ばれたものは 0.9。あとで合計 1 にそろえる）。
    public init(target: String?, others: Double = 0.01) {
        self.target = target
        self.others = others
    }

    public var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
    public var widest: Int { lock.lock(); defer { lock.unlock() }; return widestCount }

    public func score(state: String, question: String, options: [String]) throws -> [Double] {
        lock.lock()
        callCount += 1
        widestCount = max(widestCount, options.count)
        lock.unlock()
        var p = options.map { _ in others }
        p[options.firstIndex { $0 == target } ?? options.count - 1] = 0.9
        let sum = p.reduce(0, +)
        return p.map { $0 / sum }
    }
}

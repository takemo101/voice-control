import Foundation
import VCDecision

/// 選択肢に出てきた文を覚える偽物（確率は、どれも同じ）。「どの候補が、問いに出たか」を確かめる。
public final class OptionSpy: OptionScorer, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []

    public init() {}

    public var seen: [String] { lock.lock(); defer { lock.unlock() }; return all }

    public func score(state: String, question: String, options: [String]) throws -> [Double] {
        lock.lock(); all += options; lock.unlock()
        return options.map { _ in 1.0 / Double(options.count) }
    }
}

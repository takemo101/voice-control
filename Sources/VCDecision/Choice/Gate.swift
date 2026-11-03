import Foundation

/// 確信度のゲート。**閾値は、まだ測っていない仮の値**。
public struct Gate: Sendable {
    public enum Verdict: Equatable, Sendable {
        /// そのまま実行してよい。
        case execute
        /// 読み上げて、声で「はい」と言うまで実行しない。
        case confirm
        /// 捨てる（操作ではない、または、自信がない）。
        case reject
    }

    public var floor = 0.40
    public var execute = 0.70
    /// 「取り消しにくい操作か」の確率が、これ以上なら、確認を挟む。
    public var destructive = 0.5

    public init() {}

    /// `stages`：各段階で選んだものの確率。`destructive`：取り消しにくい操作である確率（判断しなかったら `nil`）。`forceConfirm`：必ず確認する操作。
    public func verdict(stages: [Double], destructive risk: Double?, forceConfirm: Bool) -> Verdict {
        guard let weakest = stages.min(), weakest >= floor else { return .reject }
        if forceConfirm || (risk ?? 0) >= destructive { return .confirm }
        return weakest >= execute ? .execute : .confirm
    }
}

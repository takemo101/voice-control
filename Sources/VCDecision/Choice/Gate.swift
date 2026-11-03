import Foundation

/// 確信度のしきい値。**閾値は、まだ測っていない仮の値**。`SkillResolver`（VCSkill）が、スキルを選んだ確信度・確認の要否に使う。
public struct Gate: Sendable {
    /// スキルを選んだ確信度の下限（未満なら、選ばなかったことにする）。
    public var floor = 0.40
    /// この確信度以上なら、確認なしで実行してよい（未満なら、確認する）。
    public var execute = 0.70
    /// 「取り消しにくい操作か」の確率が、これ以上なら、確認を挟む。
    public var destructive = 0.5

    public init() {}
}

import Foundation

/// どのスキルを呼ぶか（Tiny-Jev）。有効なスキルの `description` から選ぶ。「どれでもない」を含む。32 個を超えれば、勝ち抜き戦。
public struct SkillRouter: Sendable {
    public struct Routed: Sendable { public let skill: Skill?; public let probability: Double }
    private let chooser: Chooser
    private let skills: [Skill]

    public init(scorer: OptionScorer, skills: [Skill]) {
        chooser = Chooser(scorer: scorer)
        self.skills = skills
    }

    public func route(_ request: String) throws -> Routed {
        guard !skills.isEmpty else { return Routed(skill: nil, probability: 1) }
        let pick = try chooser.pick(state: request, question: "この依頼は、どのスキルを呼ぶものか", options: skills.map(\.description), none: "どのスキルでもない（会話・独り言）")
        return Routed(skill: pick.index.map { skills[$0] }, probability: pick.probability)
    }
}

import Foundation
import Testing
import TestSupport
@testable import VCSkill

/// スキルのルーター（`SkillRouter`）：渡したスキルだけを、選択肢に出す。
@Suite struct SkillRouterTests {
    @Test func routerOffersOnlyTheSkillsItIsGiven() throws {
        func skill(_ n: String) -> Skill { Skill(name: n, description: "説明 \(n)", allowedCommands: ["open"], confirm: false, body: "b", file: URL(fileURLWithPath: "/tmp/x")) }
        let spy = OptionSpy()
        _ = try SkillRouter(scorer: spy, skills: [skill("a")]).route("依頼")
        #expect(spy.seen.contains("説明 a") && !spy.seen.contains("説明 b"))
        #expect(try SkillRouter(scorer: spy, skills: []).route("依頼").skill == nil)
    }
}

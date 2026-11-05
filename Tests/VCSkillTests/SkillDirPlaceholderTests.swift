import Foundation
import Testing
@testable import VCSkill

/// `${SKILL_DIR}`：スクリプトを同梱するスキルを、置き場所（グローバル・プロジェクト）に関わらず、同じ SKILL.md で動かす。
@Suite struct SkillDirPlaceholderTests {
    private func load(dir: String) throws -> Skill {
        try SkillStore.parse("""
        ---
        name: demo
        description: x
        allowed-commands:
          - osascript ${SKILL_DIR}/run.applescript
        ---
        Run: osascript ${SKILL_DIR}/run.applescript <action>
        """, directoryName: "demo", file: URL(fileURLWithPath: "\(dir)/demo/SKILL.md")).get()
    }

    @Test func theDirectoryOfTheSkillReplacesThePlaceholderInCommandsAndBody() throws {
        let skill = try load(dir: "/home/u/.voice-control/skills")
        #expect(skill.allowedCommands == ["osascript /home/u/.voice-control/skills/demo/run.applescript"])
        #expect(skill.body == "Run: osascript /home/u/.voice-control/skills/demo/run.applescript <action>")
    }

    /// 置き場所が違っても、同じ SKILL.md で、その場所のスクリプトを指す（グローバルに置いたとき、相対パスで失敗しない）。
    @Test func theSamePlaceholderFollowsTheSkillToWhereverItIsPlaced() throws {
        let a = try load(dir: "/home/u/.voice-control/skills"), b = try load(dir: "/work/proj/.voice-control/skills")
        #expect(a.allowedCommands != b.allowedCommands)
        #expect(b.allowedCommands == ["osascript /work/proj/.voice-control/skills/demo/run.applescript"])
    }

    /// 置き換えたコマンドは、許可の照合を、そのまま通る。空白を含むパスでも、1 つの引数として読まれ、ほかのスクリプトは通らない。
    @Test func theExpandedCommandStillMatchesThePolicyEvenWithSpacesInThePath() throws {
        let skill = try load(dir: "/Users/Some One/.voice-control/skills")
        let script = "/Users/Some One/.voice-control/skills/demo/run.applescript"
        #expect(CommandPolicy.check(argv: ["osascript", script, "play"], allowed: skill.allowedCommands) == nil)
        #expect(CommandPolicy.check(argv: ["osascript", "/tmp/evil.applescript", "play"], allowed: skill.allowedCommands) != nil)
    }

    @Test func aSkillWithoutThePlaceholderIsLeftAsWritten() throws {
        let skill = try parse("---\nname: demo\ndescription: x\nallowed-commands: osascript .voice-control/skills/demo/run.applescript\n---\nbody").get()
        #expect(skill.allowedCommands == ["osascript .voice-control/skills/demo/run.applescript"])
    }
}

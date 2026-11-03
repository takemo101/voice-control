import Foundation
import Testing
@testable import VCSkill

@Suite struct AllowedCommandsSyntaxTests {
    @Test func normalizesClaudeCodeStyleEntries() throws {
        #expect(try CommandPolicy.normalize("Bash(open -a *)").get() == ["open", "-a"])
        #expect(try CommandPolicy.normalize("Bash(ls:*)").get() == ["ls"])
        #expect(try CommandPolicy.normalize("agent-desktop click *").get() == ["agent-desktop", "click"])
        #expect(try CommandPolicy.normalize("Bash(open -a Spotify)").get() == ["open", "-a", "Spotify"])
        #expect(throws: CommandPolicy.Violation.self) { try CommandPolicy.normalize("Read(./.env)").get() }
        #expect(throws: CommandPolicy.Violation.self) { try CommandPolicy.normalize("Bash(*)").get() }
    }

    @Test func wildcardInsideATokenMatchesOnlyThatToken() {
        let allowed = ["agent-desktop click @a*", "open -a *.app"]
        #expect(CommandPolicy.check(argv: ["agent-desktop", "click", "@a1:e3"], allowed: allowed) == nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "click", "@s1:e3"], allowed: allowed) != nil)   // 本物の参照の形は、通さない
        #expect(CommandPolicy.check(argv: ["open", "-a", "Safari.app"], allowed: allowed) == nil)
        #expect(CommandPolicy.check(argv: ["open", "-a", "Safari"], allowed: allowed) != nil)
    }

    @Test func aStandaloneStarInTheMiddleMatchesExactlyOneToken() {
        let allowed = ["agent-desktop * @a1:e1"]
        #expect(CommandPolicy.check(argv: ["agent-desktop", "click", "@a1:e1"], allowed: allowed) == nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "@a1:e1"], allowed: allowed) != nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "click", "@a1:e2"], allowed: allowed) != nil)
    }

    @Test func prefixSemanticsAreUnchangedAndShellTricksStillFail() {
        // `*` のない項目は、前方一致のまま（Claude Code の「完全一致」とは違う）。末尾の `*` は、あってもなくても同じ。
        #expect(CommandPolicy.check(argv: ["open", "-a", "Safari"], allowed: ["open"]) == nil)
        #expect(CommandPolicy.check(argv: ["open", "-a", "Safari"], allowed: ["Bash(open *)"]) == nil)
        #expect(CommandPolicy.check(argv: ["timeout", "30", "open", "x"], allowed: ["open"]) != nil)   // ラッパーは外さない
        #expect(CommandPolicy.check(argv: ["open", "x;", "rm"], allowed: ["open"]) == nil)             // `;` は、ただの引数
    }

    @Test func entriesThatWouldWidenThePermissionAreRejectedAtLoadTime() {
        #expect(CommandPolicy.validateEntry("* --version") != nil)       // コマンド名の `*`
        #expect(CommandPolicy.validateEntry("Bash(sudo *)") != nil)      // 禁止コマンド
        #expect(CommandPolicy.validateEntry("Read(./x)") != nil)         // Bash 以外のツール
        #expect(CommandPolicy.validateEntry("Bash(open -a *)") == nil)
    }

    @Test func skillFilesAcceptTheBashWrappedForm() throws {
        let skill = try parse("---\nname: demo\ndescription: x\nallowed-commands:\n  - Bash(open -a *)\n  - Bash(agent-desktop click @a*)\n---\nbody").get()
        #expect(skill.allowedCommands == ["Bash(open -a *)", "Bash(agent-desktop click @a*)"])
    }
}

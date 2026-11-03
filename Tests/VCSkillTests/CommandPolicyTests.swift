import Foundation
import Testing
@testable import VCSkill

@Suite struct CommandPolicyTests {
    private let allowed = ["open", "agent-desktop click", "agent-desktop snapshot"]

    @Test func tokenizesLikeAShellWithoutRunningOne() throws {
        #expect(try CommandPolicy.tokenize(#"open -a "Google Chrome""#).get() == ["open", "-a", "Google Chrome"])
        #expect(try CommandPolicy.tokenize("say 'a b' c\\ d").get() == ["say", "a b", "c d"])
        // シェルの記号は、ただの文字：実行されない
        #expect(try CommandPolicy.tokenize("open -a Safari; rm -rf /").get() == ["open", "-a", "Safari;", "rm", "-rf", "/"])
        #expect(throws: CommandPolicy.Violation.self) { try CommandPolicy.tokenize("open 'x").get() }
    }

    @Test func allowsOnlyCommandsMatchingAnAllowedPrefix() {
        #expect(CommandPolicy.check(argv: ["open", "-a", "Safari"], allowed: allowed) == nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "click", "@a1:e3"], allowed: allowed) == nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "type", "@a1:e3", "x"], allowed: allowed) != nil)   // サブコマンドが違う
        #expect(CommandPolicy.check(argv: ["rm", "-rf", "/"], allowed: allowed) != nil)
        #expect(CommandPolicy.check(argv: [], allowed: allowed) != nil)
    }

    @Test func neverAllowsShellsPathsOrForce() {
        #expect(CommandPolicy.check(argv: ["bash", "-c", "ls"], allowed: ["bash"]) != nil)
        #expect(CommandPolicy.check(argv: ["env", "rm"], allowed: ["env"]) != nil)
        #expect(CommandPolicy.check(argv: ["/usr/bin/open", "x"], allowed: ["open"]) != nil)
        #expect(CommandPolicy.check(argv: ["agent-desktop", "press", "cmd+q", "--force"], allowed: ["agent-desktop"]) != nil)
        #expect(CommandPolicy.validateEntry("sudo") != nil)
        #expect(CommandPolicy.validateEntry("agent-desktop click") == nil)
    }
}

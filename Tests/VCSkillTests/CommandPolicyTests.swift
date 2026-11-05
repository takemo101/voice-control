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

/// `"…"` の中の `\n`・`\t` は、改行・タブ（言語モデルが、複数行の文字を、`\n` と書いて渡す）。それ以外の `\` は、次の文字をそのまま。
@Suite struct TokenizeEscapeTests {
    private func tokens(_ s: String) throws -> [String] { try CommandPolicy.tokenize(s).get() }

    @Test func backslashNAndTInsideDoubleQuotesBecomeNewlineAndTab() throws {
        #expect(try tokens("vc show --text \"# 題\\n\\n- 項目\\tA\"") == ["vc", "show", "--text", "# 題\n\n- 項目\tA"])
    }

    @Test func otherEscapesAreUnchanged() throws {
        #expect(try tokens("echo a\\ b") == ["echo", "a b"])                 // 引用符の外の `\ ` は、空白そのまま
        #expect(try tokens("echo \\n") == ["echo", "n"])                      // 引用符の外の `\n` は、n のまま
        #expect(try tokens("echo \"say \\\"hi\\\" \\\\ done\"") == ["echo", "say \"hi\" \\ done"])
        #expect(try tokens("echo '\\n'") == ["echo", "\\n"])                // 単一引用符の中は、そのまま
    }
}

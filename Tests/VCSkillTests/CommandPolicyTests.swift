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

/// 許可の先頭を落とした引数だけのコマンドは、許可が 1 項目のスキルに限り、先頭を補う（権限は広がらない）。
@Suite struct CommandPolicyCompletionTests {
    private let spotify = ["osascript /skills/spotify/spotify.applescript"]

    private func complete(_ command: String, allowed: [String]) -> String? {
        guard case let .success(argv) = CommandPolicy.tokenize(command) else { return nil }
        return CommandPolicy.completed(command: command, argv: argv, allowed: allowed)?.command
    }

    @Test func aMissingPrefixIsCompletedForASingleEntrySkill() {
        #expect(complete("volume 50", allowed: spotify) == "osascript /skills/spotify/spotify.applescript volume 50")
        #expect(complete(#"search "next""#, allowed: spotify) == #"osascript /skills/spotify/spotify.applescript search "next""#)
        #expect(complete("play-liked", allowed: spotify) == "osascript /skills/spotify/spotify.applescript play-liked")
    }

    /// すでに許可なら、補わない。許可が複数ある（先頭が 1 つに決まらない）スキルは、補わない。
    @Test func nothingIsCompletedWhenAlreadyAllowedOrAmbiguous() {
        #expect(complete("osascript /skills/spotify/spotify.applescript next", allowed: spotify) == nil)
        #expect(complete("volume 50", allowed: ["open", "say"]) == nil)
        #expect(complete("volume 50", allowed: []) == nil)
    }

    /// 許可のプログラムで始まっている（書き忘れでなく、許可にない書き方）・許可が、スクリプトのパスでない・PATH にある実在のコマンドは、補わない。
    @Test func onlyAForgottenInterpreterPrefixIsCompleted() {
        #expect(complete("osascript /skills/other.applescript next", allowed: spotify) == nil)   // 別のスクリプト：拒否のまま
        #expect(complete("play-liked", allowed: ["vc fillers add"]) == nil)   // 許可が、スクリプトのパスでない
        #expect(complete("play-liked", allowed: ["echo"]) == nil)
        for real in ["rm -rf /tmp/x", "open -a Spotify", "curl https://example.com", "ls"] { #expect(complete(real, allowed: spotify) == nil, "\(real)") }
    }

    /// シェル・権限を上げる名前・パスで始まるコマンドは、補わず、拒否のまま。
    @Test func forbiddenProgramsAndPathsAreNeverCompleted() {
        for command in ["sudo reboot", "sh -c ls", "bash script.sh", "env FOO=1 ls", "/bin/rm -rf /tmp/x", "./run.sh"] {
            #expect(complete(command, allowed: spotify) == nil, "\(command)")
        }
    }

    /// 補ったあとも、許可の先頭 + 引数：シェルの記号は、ただの引数の文字（実行されない）。
    @Test func shellSyntaxStaysPlainArguments() {
        let completed = CommandPolicy.completed(command: "next; rm -rf ~", argv: ["next;", "rm", "-rf", "~"], allowed: spotify)
        #expect(completed?.argv == ["osascript", "/skills/spotify/spotify.applescript", "next;", "rm", "-rf", "~"])
    }
}

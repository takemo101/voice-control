import Foundation
import Testing
@testable import VCSkill

/// 長いコマンドの、確認用の要約：**実際に、利用者が見て、読めなかった**コマンド（Codex が、Markdown を書く python3 のコード）で。
@Suite struct ACPCommandSummaryTests {
    private let real = ##"python3 -c 'from pathlib import Path; Path("security-news-detail.md").open("x", encoding="utf-8").write("""# サイバーセキュリティニュース詳細  2026年11月18日時点で確認した情報です。  ## Microsoft 製品のセキュリティー更新  Microsoftは2026年11月の月例更新で、Outlookの脆弱性「CVE-2026-124194」などを修正しました。週次ニュースまとめによると、この脆弱性は実際の攻撃で悪用が確認されており、JPCERT/CC と IPA が注意を呼びかけています。利用者や管理者は、利用中の Microsoft 製品に該当する更新を確認し、適用することが推奨されます。  出典：[セキュリティニュース週次まとめ（11月9日〜15日）](https://www.nowledge.co.jp/security-news/2026-11-16-weekly/)  ## 冷凍・冷蔵設備へのサイバー攻撃  欧州のスーパーマーケットで冷蔵設備がサイバー攻撃を受けました。""")'"##

    @Test func aLongPythonScriptIsSummarizedByProgramTargetFileAndSize() {
        let summary = ACPCommandSummary.summarize(real)
        #expect(summary.headline.hasPrefix("python3 のコードを実行：security-news-detail.md を新しく作る（全 "))
        #expect(summary.headline.hasSuffix(" 文字）") && summary.headline.count < 80)                  // 1 行で、読める長さ
        #expect(summary.preview.hasPrefix("python3 -c 'from pathlib import Path;") && summary.preview.contains("略しています"))
        #expect(summary.preview.count < 200)                                                          // 抜粋も、短い
    }

    @Test func shortCommandsAreShownAsTheyAre() {
        #expect(ACPCommandSummary.summarize("ls -la") == .init(headline: "ls -la", preview: ""))
        let ninety = "echo " + String(repeating: "x", count: 90)
        #expect(ACPCommandSummary.summarize(ninety).preview.isEmpty && ACPCommandSummary.summarize(ninety).headline == ninety)
    }

    @Test func theProgramIsFoundPastCdSetAndVariablePrefixes() {
        #expect(ACPCommandSummary.programName(of: #"cd "/tmp/work dir" && python3 x.py"#) == "python3")
        #expect(ACPCommandSummary.programName(of: #"cd "/tmp/work" && python3 x.py"#) == "python3")
        #expect(ACPCommandSummary.programName(of: "set -C; printf '%s' hi > a.txt") == "printf")
        #expect(ACPCommandSummary.programName(of: "( set -o noclobber; cat > a.txt )") == "cat")
        #expect(ACPCommandSummary.programName(of: "FOO=1 BAR=2 /usr/bin/node app.js") == "node")
        #expect(ACPCommandSummary.programName(of: "/opt/homebrew/bin/rg -n foo") == "rg")
        #expect(ACPCommandSummary.programName(of: "") == "コマンド")
    }

    @Test func writtenFilesAreFoundInPythonAndShellForms() {
        func files(_ command: String) -> [String] { ACPCommandSummary.writtenFiles(in: command).map { "\($0.file):\($0.verb)" } }
        #expect(files(#"python3 -c 'open("a.txt", "w").write("x")'"#) == ["a.txt:書き込む"])
        #expect(files(#"python3 -c 'open("a.txt","a")'"#) == ["a.txt:追記する"])
        #expect(files(#"python3 -c 'Path("n.md").write_text("x")'"#) == ["n.md:書き込む"])
        #expect(files("set -C; printf hi > check.txt") == ["check.txt:書き込む"])
        #expect(files("echo a >> log.txt") == ["log.txt:追記する"])
        #expect(files("echo hi | tee -a out.log") == ["out.log:追記する"] && files("echo hi | tee out.log") == ["out.log:書き込む"])
        #expect(files("ls 2>&1 | head") .isEmpty && files("cmd > /dev/null 2>&1").isEmpty && files("echo a >&2").isEmpty)   // 出力の付け替えは、ファイルでない
        #expect(files("grep foo a.txt").isEmpty)
    }

    @Test func theConfirmationDetailForALongCommandHasAHeadlineLineThenAnExcerptAndKeepsTheFullCommandOutOfIt() {
        let call = ACPToolCall(kind: "execute", command: real)
        let detail = ACPPermissionText.detail(call, folder: URL(fileURLWithPath: "/tmp/w"))
        let lines = detail.components(separatedBy: "\n")
        #expect(lines.count == 2 && lines[0].hasPrefix("コマンドを実行する：python3 のコードを実行：security-news-detail.md を新しく作る"))
        #expect(detail.count < 330 && !detail.contains("冷凍・冷蔵設備"))                                  // 末尾の本文は、確認の文に、並ばない（全文は、実行した操作に残る）
    }

    @Test func shellSyntaxWordsAreNotMistakenForTheProgram() {
        // Claude が実際に出した形：`if [ -e … ]; then echo EXISTS; else printf … > /tmp/x; fi`
        let command = #"if [ -e /tmp/vc-chat-check-outside.txt ]; then echo "EXISTS"; else printf 'hi\n' > /tmp/vc-chat-check-outside.txt; fi && cat /tmp/vc-chat-check-outside.txt && echo done"#
        let summary = ACPCommandSummary.summarize(command)
        #expect(summary.headline.hasPrefix("シェルのスクリプトを実行：/tmp/vc-chat-check-outside.txt を書き込む（全 "))
    }
}


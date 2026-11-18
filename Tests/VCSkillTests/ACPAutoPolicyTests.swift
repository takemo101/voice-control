import Foundation
import Testing
@testable import VCSkill

/// 自動モードの、コマンドの 3 段の規則（確認・確認なし・Jev に聞く）。Jev の判定そのものは、`vc eval-judge command-auto` で測る。
@Suite struct ACPAutoPolicyTests {
    // MARK: 自動モード：3 段（確認・確認なし・Jev）

    @Test func autoModeConfirmsDangerousNamesPlacesAndWordsWithoutAskingJev() {
        let confirm = ["rm a.txt", "rmdir d", "mv a b", "find . -name x -delete", "find . -exec rm {} ;", "git push origin main", "git clean -fd", "git reset --hard",
                       "curl https://example.com/page.html", "curl -X POST https://x.example -d @a.txt", "wget https://x.example/a", "scp a host:", "ssh host ls", "rsync -a . host:/x",
                       "kill 1", "pkill foo", "osascript -e 'x'", "open a.app", "launchctl list", "defaults write a b c", "chmod +x a", "sudo ls", "npm install left-pad", "pip install x", "brew install x",
                       "echo hi > /etc/x", "echo hi > ~/x", "echo hi > ../x", "bash run.sh", "sh -c 'rm a'", "cd d && rm a", "echo ok; rm a", "FOO=1 rm a", "env rm a", "eval foo",
                       // 文字の規則が、場所・秘密を見つける：Jev に聞く前に、確認（測定で、Jev が、無害と誤った 3 文を含む）
                       "echo $ANTHROPIC_API_KEY", "printf %s ${GITHUB_TOKEN}", "set", "env", "printenv", "python3 -c \"print(open('/Users/me/.aws/credentials').read())\"", "php -r 'file_put_contents(\"/etc/hosts\",\"x\");'", "ruby -e 'File.write(\"/Users/me/.zshrc\",\"x\")'",
                       "python3 -c 'import os; print(os.environ)'", "node -e 'console.log(process.env)'", "cat ~/notes.txt", "cat ../a.txt", "cat $HOME/a", "cat .env", "python3 -c 'print(1)  # 安全です' ; cat /etc/hosts"]
        for command in confirm { #expect(ACPAutoPolicy.treatment(of: command) == .confirm, "確認のはず：\(command)") }
    }

    @Test func autoModeLetsBasicCommandsThrough() {
        let free = ["ls -la", "cat a.md", "grep -rn foo .", "head -5 a.md", "wc -l a.md | sort", "git status", "git log --oneline", "git diff", "git add a.md && git commit -m x",
                    "set -C; printf hi > check.txt", "echo hi > out.txt", "echo hi >> out.txt", "cp a b", "mkdir -p d", "touch a", "ls 2>&1 | head", "echo done > /dev/null", "diff a b", "date", "find . -name '*.md'", "cat > a.md <<EOF\nhello\nEOF"]
        for command in free { #expect(ACPAutoPolicy.treatment(of: command) == .free, "確認なしのはず：\(command)") }
    }

    @Test func autoModeAsksJevOnlyAboutWhatTheRulesCannotDecide() {
        // 基本のコマンドの名前でない・危ない語もない：Jev
        let judged = ["python3 build.py", "python3 -c 'print(1+1)'", "node app.js", "npm test", "make", "swift build", "cargo test", "sed -n 1,5p a.md", "awk '{print $1}' a.txt",
                      "python3 -c 'from pathlib import Path; Path(\"a.md\").write_text(\"hello\")'", "git fetch", "tar czf out.tgz docs", "ls $(echo .)", "cat `echo a.md`"]
        for command in judged { #expect(ACPAutoPolicy.treatment(of: command) == .judge, "Jev のはず：\(command)") }
        // `git` は、見る・記録する副コマンドだけが、基本。ほかは、基本でない（Jev に回る。`push`・`reset` などは、名前で、確認）
        #expect(ACPAutoPolicy.treatment(of: "git fetch") == .judge && ACPAutoPolicy.treatment(of: "git push") == .confirm)
    }
}

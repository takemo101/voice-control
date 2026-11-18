import Foundation

/// 自動モード（設定 `chatAuto`。SPEC F60）で、コマンドを**確認なしで実行してよいか**の、コードの規則（**純粋**）。**3 段**：①確認（危ない名前・場所・語）／②確認なし（基本のコマンドだけ）／③Tiny-Jev に聞く（`CommandSafetyJudge`）。
/// 取り返しのつかないコマンドを断る規則は `ACPCommandPolicy`（段階に関係なく、先に効く）。文字の切り分けは `ShellWords`。
enum ACPAutoPolicy {
    /// 自動モードで、コマンドを、どう扱うか。
    enum Treatment: Equatable {
        /// 確認なしで実行する（基本のコマンドだけで、できているもの）。
        case free
        /// 利用者に確認する。
        case confirm
        /// コードの規則では、決められない：Tiny-Jev に、無害かを、聞く（`CommandSafetyJudge`。無害と判定できなければ、確認）。
        case judge
    }

    /// **3 段**：① 危ない名前・危ない場所・危ない語が、1 つでもあれば、確認（Jev に聞かない：「無害だ」と、書いたコメントなどで、騙されうるため）。② 基本のコマンドだけなら、確認なし。③ ほかは、Jev。**純粋**。
    static func treatment(of command: String) -> Treatment {
        if needsConfirmationEvenInAuto(command) || mentionsSensitiveThing(command) { return .confirm }
        // 置換・展開は、コマンドの切り分けで、見えない：基本のコマンドとしては、扱わない
        let plain = command.range(of: #"`|\$\(|<\(|>\("#, options: .regularExpression) == nil
        if plain {
            // `2>&1` の `&` は、連結ではない・ヒアドキュメントの本文は、データ
            let shell = strippingHeredocBodies(command).replacingOccurrences(of: #"\d?>&\d|&>"#, with: ">", options: .regularExpression).replacingOccurrences(of: "\n", with: ";")
            let all = ShellWords.segments(of: shell)
            if !all.isEmpty, all.allSatisfy(isBasicSegment) { return .free }
        }
        return .judge
    }

    /// `cat > a.md <<EOF … EOF` の、本文の行を除く（本文は、シェルが実行しない：置換の `$(` は、別に見ている）。
    private static func strippingHeredocBodies(_ command: String) -> String {
        var out: [Substring] = [], terminator: String?
        for line in command.split(separator: "\n", omittingEmptySubsequences: false) {
            if let end = terminator { if line.trimmingCharacters(in: .whitespaces) == end { terminator = nil }; continue }
            out.append(line)
            if let range = line.range(of: #"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#, options: .regularExpression) {
                terminator = line[range].replacingOccurrences(of: #"<<-?\s*['"]?|['"]?$"#, with: "", options: .regularExpression)
            }
        }
        return out.joined(separator: "\n")
    }

    /// 基本のコマンド（見る・数える・探す・作る・写す）。名前だけで決める。`git` は、見るものと、記録する（`add`・`commit`）ものだけ：ほかの副コマンドは、基本では、ない。
    private static let basicPrograms: Set<String> = [
        "ls", "pwd", "date", "whoami", "uname", "cat", "head", "tail", "wc", "sort", "uniq", "grep", "egrep", "fgrep", "rg", "find", "diff", "cmp", "file", "stat", "tree", "du", "df", "which",
        "echo", "printf", "mkdir", "touch", "cp", "basename", "dirname", "realpath", "cut", "tr", "jq", "true", "false", "cd", "test", "[", "set",
    ]
    private static let basicGit: Set<String> = ["status", "diff", "log", "show", "branch", "rev-parse", "ls-files", "blame", "add", "commit"]

    private static func isBasicSegment(_ segment: String) -> Bool {
        let tokens = ShellWords.tokens(of: segment)
        guard let head = tokens.first else { return true }
        let program = ShellWords.name(of: head)
        if program == "git" { return tokens.dropFirst().first(where: { !$0.hasPrefix("-") }).map(basicGit.contains) ?? false }
        if program == "set" { return tokens.count > 1 && tokens.dropFirst().allSatisfy { $0.hasPrefix("-") || $0.hasPrefix("+") } }   // `set -C` は基本：引数なしの `set` は、すべての変数を出す
        return basicPrograms.contains(program) && !(program == "find" && tokens.contains(where: { ["-exec", "-execdir", "-delete", "-ok", "-fprint", "-fprintf"].contains($0) }))
    }

    /// **コードの外・秘密に触れる書き方**：絶対のパス・`~`・`$HOME`・`..`・秘密の置き場（`.ssh`・`.aws`・`.env`・鍵・資格情報・キーチェーン）・環境変数の読み取り。**Jev に聞く前に、確認に回す**（測定で、Jev は、「資格情報を読む」「設定ファイルを書く」を、無害と、誤った：docs/verification.md）。
    static func mentionsSensitiveThing(_ command: String) -> Bool {
        // 絶対のパス（`/dev/null` と URL の `//` は、除く）
        if command.range(of: #"(^|[\s"'=(,:@])/(?!dev/(null|stderr|stdout|tty)\b)[A-Za-z~_.]"#, options: .regularExpression) != nil { return true }
        if command.range(of: #"~|\$\{?HOME|(^|[\s"'=(/])\.\.($|[\s"'/)])"#, options: .regularExpression) != nil { return true }
        // 環境変数の展開（`echo $ANTHROPIC_API_KEY`：キーが、出力に出て、外のモデルへ渡る）。大文字の名前だけ（ループの `$i` は、除く）
        if command.range(of: #"\$\{?[A-Z_][A-Z0-9_]*"#, options: .regularExpression) != nil { return true }
        let lower = command.lowercased()
        return ["/.ssh", ".ssh/", ".aws", ".gnupg", ".env", "id_rsa", "id_ed25519", "credential", "keychain", "keyring", "environ", "getenv", "process.env"].contains { lower.contains($0) }
    }


    /// 自動モード（作業フォルダの中は、確認なし）でも、**利用者に確認するコマンドか**（**純粋**）：**消す**（`rm`・`find -delete`・`git clean`…）・**外へ送る・出ていく**（`curl` の送信・`scp`・`ssh`・`git push`…）・プロセスやシステムを動かす（`kill`・`launchctl`・`osascript`・`open`・`defaults`…）・インストール・権限の変更。
    /// **文字を見る限りの安全網**（網羅ではない）。コードの中（`python3 -c` の `os.remove`）は、見抜けない：書き込みの範囲は、OS の制限（Seatbelt）が、作業フォルダに限る。取り返しのつかないもの（`isCatastrophic`）は、別に、断る。
    static func needsConfirmationEvenInAuto(_ command: String) -> Bool {
        let flat = command.replacingOccurrences(of: "\n", with: ";")
        for segment in ShellWords.segments(of: flat) {
            let bare = ShellWords.tokens(of: segment)
            if bare.count == 1, ["set", "env"].contains(ShellWords.name(of: bare[0])) { return true }   // 引数なしは、すべての変数を出す
            let tokens = ShellWords.strippingWrappers(bare)
            guard let head = tokens.first else { continue }
            let program = ShellWords.name(of: head)
            let rest = Array(tokens.dropFirst())
            if confirmAlways.contains(program) { return true }
            if ShellWords.shells.contains(program) {   // シェルで、別のコマンドを動かす：`-c` の中身を見る。スクリプトのファイルは、中身が分からない
                if let c = rest.firstIndex(of: "-c"), c + 1 < rest.count { if needsConfirmationEvenInAuto(rest[(c + 1)...].joined(separator: " ")) { return true } } else { return true }
            }
            switch program {
            case "find": if rest.contains("-delete") || rest.contains("-exec") || rest.contains("-execdir") { return true }
            case "git": if let sub = rest.first(where: { !$0.hasPrefix("-") }), ["push", "clean", "reset", "rebase", "checkout", "restore", "stash", "remote", "config"].contains(sub) { return true }
            case "npm", "pnpm", "yarn", "bun", "pip", "pip3", "pipx", "uv", "brew", "gem", "cargo", "go", "swift": if rest.contains(where: { ["install", "i", "add", "publish", "uninstall", "remove", "update", "upgrade", "global", "-g", "--global"].contains($0) }) { return true }
            case "defaults": return true
            case "ln": if rest.contains("-sf") || rest.contains("-fs") { return true }
            default: break
            }
            if ACPCommandPolicy.isCatastrophicSegment(segment, home: NSHomeDirectory(), depth: 0) { return true }
        }
        // 出力の付け替えで、ファイルの外（絶対のパス・`..`・ホーム）へ書く
        if command.range(of: #">>?\s*["']?(/|~|\.\./|\$HOME|\$\{HOME\})"#, options: .regularExpression) != nil, command.range(of: #">>?\s*["']?/dev/(null|stderr|stdout|tty)"#, options: .regularExpression) == nil { return true }
        return false
    }

    private static let confirmAlways: Set<String> = [
        "rm", "rmdir", "unlink", "shred", "trash", "srm", "mv", "chmod", "chown", "chgrp", "chflags", "xattr", "kill", "pkill", "killall", "launchctl", "osascript", "open", "crontab", "at",
        "ssh", "scp", "sftp", "rsync", "curl", "wget", "nc", "ncat", "netcat", "telnet", "ftp", "mount", "umount", "hdiutil", "diskutil", "tmutil", "systemsetup", "scutil", "networksetup", "pmset", "security", "spctl", "csrutil", "dscl", "sysctl",
        "sudo", "doas", "su", "pkexec", "eval", "source", ".", "exec", "printenv", "export", "declare",
    ]
}

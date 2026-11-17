import Foundation
import VCCore

/// 会話のエージェントが実行しようとする**コマンド**の、2 つの規則（**純粋**：シェルを動かさず、文字だけで見る）。
/// - **断る**（`isCatastrophic`）：取り返しのつかない操作（ルート・ホーム・作業フォルダ・親フォルダの再帰削除、権限昇格、ディスクの消去、取ってきたものをシェルへ渡す…）。**段階・確認に関係なく、断る**（パネルも出さない）。
/// - **確認なしで許す**（`isHarmlessInFolder`）：作業フォルダの中の、一覧・日時・名前などを見るだけの、ごく小さな一組（`ls`・`pwd`・`date`・`whoami`・`uname`）。ファイルの**中身**を読むコマンド（`cat`・`head`…）は、入れない（鍵などを、外のモデルへ送る道になる）。
/// どちらも、**網羅ではない**：文字を見る限りの、最小限の安全網（Zed の組み込みの拒否規則の考え方に倣った）。シェルの仕組み（変数・置換）を使った、回りくどい書き方は、見抜けない：**見抜けないものは、断らず、確認に回す**（許す側は、判断できないものを、必ず確認に回す）。
enum ACPCommandPolicy {
    // MARK: 断る

    /// 取り返しのつかない操作か。
    static func isCatastrophic(_ command: String, home: String = NSHomeDirectory()) -> Bool {
        // 取ってきたものを、そのままシェルへ渡す（`curl … | sh`）
        if command.range(of: #"\|\s*(sudo\s+)?(ba|z|da|k)?sh\b"#, options: .regularExpression) != nil { return true }
        // フォーク爆弾
        if command.range(of: #":\s*\(\s*\)\s*\{"#, options: .regularExpression) != nil { return true }
        // ディスクへの直接の書き込み
        if command.range(of: #">\s*/dev/(r?disk|sd)"#, options: .regularExpression) != nil { return true }
        return segments(of: command).contains { isCatastrophicSegment($0, home: home, depth: 0) }
    }

    private static let privilege: Set<String> = ["sudo", "doas", "su", "pkexec"]
    private static let wrappers: Set<String> = ["env", "command", "nohup", "time", "nice", "exec", "builtin", "caffeinate"]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    private static let machine: Set<String> = ["shutdown", "reboot", "halt", "mkfs", "newfs"]
    private static let systemRoots: Set<String> = ["/usr", "/etc", "/bin", "/sbin", "/System", "/Library", "/Users", "/Applications", "/var", "/private", "/opt", "/Volumes"]

    private static func isCatastrophicSegment(_ segment: String, home: String, depth: Int) -> Bool {
        guard depth < 4 else { return false }
        var tokens = words(segment)
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-"), !first.hasPrefix("=") { tokens.removeFirst() }   // FOO=bar cmd
        while let first = tokens.first, wrappers.contains(name(of: first)) { tokens.removeFirst() }
        guard let head = tokens.first else { return false }
        let command = name(of: head)
        let rest = Array(tokens.dropFirst())
        if privilege.contains(command) || machine.contains(command) || command.hasPrefix("mkfs") { return true }
        switch command {
        case "rm":
            guard isRecursive(rest) else { return false }
            return rest.filter { !$0.hasPrefix("-") }.contains { isDangerousTarget($0, home: home) }
        case "find":
            guard rest.contains("-delete") || rest.contains("-exec") else { return false }
            return rest.prefix { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" }.contains { isDangerousTarget($0, home: home) }
        case "dd":
            return rest.contains { $0.hasPrefix("of=/dev/") }
        case "diskutil":
            return rest.contains { ["eraseDisk", "eraseVolume", "partitionDisk", "reformat", "zeroDisk", "randomDisk", "secureErase"].contains($0) }
        case "chmod", "chown", "chgrp":
            return isRecursive(rest) && rest.filter { !$0.hasPrefix("-") }.dropFirst().contains { isDangerousTarget($0, home: home) }
        case "eval":
            return isCatastrophic(rest.joined(separator: " "), home: home)
        case "xargs":
            let inner = Array(rest.drop { $0.hasPrefix("-") })
            return isCatastrophicSegment(inner.joined(separator: " "), home: home, depth: depth + 1)
        default:
            if shells.contains(command), let c = rest.firstIndex(of: "-c"), c + 1 < rest.count {
                return isCatastrophic(rest[(c + 1)...].joined(separator: " "), home: home)
            }
            return false
        }
    }

    /// 再帰（`-r`・`-R`・`-rf`・`-fr`・`--recursive`）の指定があるか。
    private static func isRecursive(_ args: [String]) -> Bool {
        args.contains { arg in
            if arg == "--recursive" { return true }
            guard arg.hasPrefix("-"), !arg.hasPrefix("--") else { return false }
            return arg.dropFirst().contains { $0 == "r" || $0 == "R" }
        }
    }

    /// 消えると取り返しがつかない場所（ルート・ホーム・作業フォルダ・親・システムの主なフォルダ・変数や置換で決まる場所）。
    private static func isDangerousTarget(_ operand: String, home: String) -> Bool {
        var target = operand
        while target.count > 1, target.hasSuffix("/") { target.removeLast() }
        if target.hasSuffix("/*") { target.removeLast(2); if target.isEmpty { target = "/" } }
        if target.hasSuffix("/.") { target.removeLast(2); if target.isEmpty { target = "/" } }
        if ["/", "~", ".", "..", "*", "$HOME", "${HOME}", "~/.", "../.."].contains(target) || target.hasPrefix("../..") { return true }
        if target == home || target == (home as NSString).deletingLastPathComponent { return true }
        if systemRoots.contains(target) { return true }
        // 変数・置換で、行き先が決まるもの：見抜けない（再帰の削除では、断る）
        return target.contains("$(") || target.contains("`") || (target.hasPrefix("$") && target != "$HOME")
    }

    // MARK: 自動モード：コードの規則で決めて、残りだけ Tiny-Jev

    /// 自動モードで、コマンドを、どう扱うか。
    enum AutoClass: Equatable {
        /// 確認なしで実行する（基本のコマンドだけで、できているもの）。
        case free
        /// 利用者に確認する。
        case confirm
        /// コードの規則では、決められない：Tiny-Jev に、無害かを、聞く（`CommandSafetyJudge`。無害と判定できなければ、確認）。
        case judge
    }

    /// **3 段**：① 危ない名前・危ない場所・危ない語が、1 つでもあれば、確認（Jev に聞かない：「無害だ」と、書いたコメントなどで、騙されうるため）。② 基本のコマンドだけなら、確認なし。③ ほかは、Jev。**純粋**。
    static func autoClass(_ command: String) -> AutoClass {
        if needsConfirmationEvenInAuto(command) || mentionsSensitiveThing(command) { return .confirm }
        // 置換・展開は、コマンドの切り分けで、見えない：基本のコマンドとしては、扱わない
        let plain = command.range(of: #"`|\$\(|<\(|>\("#, options: .regularExpression) == nil
        if plain {
            // `2>&1` の `&` は、連結ではない・ヒアドキュメントの本文は、データ
            let shell = strippingHeredocBodies(command).replacingOccurrences(of: #"\d?>&\d|&>"#, with: ">", options: .regularExpression).replacingOccurrences(of: "\n", with: ";")
            let all = segments(of: shell)
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
        var tokens = words(segment)
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-"), !first.hasPrefix("=") { tokens.removeFirst() }
        guard let head = tokens.first else { return true }
        let program = name(of: head)
        if program == "git" { return tokens.dropFirst().first(where: { !$0.hasPrefix("-") }).map(basicGit.contains) ?? false }
        return basicPrograms.contains(program) && !(program == "find" && tokens.contains(where: { ["-exec", "-execdir", "-delete", "-ok", "-fprint", "-fprintf"].contains($0) }))
    }

    /// **コードの外・秘密に触れる書き方**：絶対のパス・`~`・`$HOME`・`..`・秘密の置き場（`.ssh`・`.aws`・`.env`・鍵・資格情報・キーチェーン）・環境変数の読み取り。**Jev に聞く前に、確認に回す**（測定で、Jev は、「資格情報を読む」「設定ファイルを書く」を、無害と、誤った：docs/verification.md）。
    static func mentionsSensitiveThing(_ command: String) -> Bool {
        // 絶対のパス（`/dev/null` と URL の `//` は、除く）
        if command.range(of: #"(^|[\s"'=(,:@])/(?!dev/(null|stderr|stdout|tty)\b)[A-Za-z~_.]"#, options: .regularExpression) != nil { return true }
        if command.range(of: #"~|\$\{?HOME|(^|[\s"'=(/])\.\.($|[\s"'/)])"#, options: .regularExpression) != nil { return true }
        let lower = command.lowercased()
        return ["/.ssh", ".ssh/", ".aws", ".gnupg", ".env", "id_rsa", "id_ed25519", "credential", "keychain", "keyring", "environ", "getenv", "process.env"].contains { lower.contains($0) }
    }


    /// 自動モード（作業フォルダの中は、確認なし）でも、**利用者に確認するコマンドか**（**純粋**）：**消す**（`rm`・`find -delete`・`git clean`…）・**外へ送る・出ていく**（`curl` の送信・`scp`・`ssh`・`git push`…）・プロセスやシステムを動かす（`kill`・`launchctl`・`osascript`・`open`・`defaults`…）・インストール・権限の変更。
    /// **文字を見る限りの安全網**（網羅ではない）。コードの中（`python3 -c` の `os.remove`）は、見抜けない：書き込みの範囲は、OS の制限（Seatbelt）が、作業フォルダに限る。取り返しのつかないもの（`isCatastrophic`）は、別に、断る。
    static func needsConfirmationEvenInAuto(_ command: String) -> Bool {
        let flat = command.replacingOccurrences(of: "\n", with: ";")
        for segment in segments(of: flat) {
            var tokens = words(segment)
            while let first = tokens.first, first.contains("="), !first.hasPrefix("-"), !first.hasPrefix("=") { tokens.removeFirst() }
            while let first = tokens.first, wrappers.contains(name(of: first)) { tokens.removeFirst() }
            guard let head = tokens.first else { continue }
            let program = name(of: head)
            let rest = Array(tokens.dropFirst())
            if confirmAlways.contains(program) { return true }
            if shells.contains(program) {   // シェルで、別のコマンドを動かす：`-c` の中身を見る。スクリプトのファイルは、中身が分からない
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
            if isCatastrophicSegment(segment, home: NSHomeDirectory(), depth: 0) { return true }
        }
        // 出力の付け替えで、ファイルの外（絶対のパス・`..`・ホーム）へ書く
        if command.range(of: #">>?\s*["']?(/|~|\.\./|\$HOME|\$\{HOME\})"#, options: .regularExpression) != nil, command.range(of: #">>?\s*["']?/dev/(null|stderr|stdout|tty)"#, options: .regularExpression) == nil { return true }
        return false
    }

    private static let confirmAlways: Set<String> = [
        "rm", "rmdir", "unlink", "shred", "trash", "srm", "mv", "chmod", "chown", "chgrp", "chflags", "xattr", "kill", "pkill", "killall", "launchctl", "osascript", "open", "crontab", "at",
        "ssh", "scp", "sftp", "rsync", "curl", "wget", "nc", "ncat", "netcat", "telnet", "ftp", "mount", "umount", "hdiutil", "diskutil", "tmutil", "systemsetup", "scutil", "networksetup", "pmset", "security", "spctl", "csrutil", "dscl", "sysctl",
        "sudo", "doas", "su", "pkexec", "eval", "source", ".", "exec",
    ]

    // MARK: 確認なしで許す

    /// 確認なしで許すコマンドか（作業フォルダの中の、見るだけのもの）。判断できない書き方は、すべて「いいえ」。
    static func isHarmlessInFolder(_ command: String, folder: URL) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return false }
        // シェルの仕組み（連結・パイプ・置換・展開・リダイレクト・引用）を含むものは、判断しない
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>`$(){}\\\n\r\"'*?[]!#~")) != nil { return false }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else { return false }
        let args = Array(parts.dropFirst())
        switch head {
        case "pwd", "whoami": return args.isEmpty
        case "date": return args.allSatisfy { $0 == "-u" }
        case "uname": return args.allSatisfy { ["-a", "-m", "-s", "-r", "-n"].contains($0) }
        case "ls":
            for arg in args {
                if arg.hasPrefix("-") { guard arg.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }), arg.count > 1 else { return false }; continue }
                guard isInside(arg, folder: folder) else { return false }
            }
            return true
        default: return false
        }
    }

    /// 作業フォルダの中の場所か（相対の場所を、実際の場所に直して、比べる：`..`・リンクで外へ出る道は、外）。
    private static func isInside(_ operand: String, folder: URL) -> Bool {
        if operand.hasPrefix("/") { return false }
        let root = RealPath.eventual(folder.path)
        let target = RealPath.eventual(folder.appendingPathComponent(operand).path)
        return RealPath.isInside(target, root: root)
    }

    // MARK: 文字の見方

    /// `;`・`&&`・`||`・`|`・`&`・改行で、区切る（引用の中も、区切る：**区切りすぎは、断る側では、見落とさず、許す側では、判断しないので、安全側**）。括弧は、外す。
    private static func segments(of command: String) -> [String] {
        command.components(separatedBy: CharacterSet(charactersIn: ";&|\n\r")).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "({ \t)}")) }.filter { !$0.isEmpty }
    }

    /// 空白で区切った語（引用符・逆スラッシュは外す）。
    private static func words(_ segment: String) -> [String] {
        segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.filter { $0 != "'" && $0 != "\"" && $0 != "\\" } }.filter { !$0.isEmpty }
    }

    private static func name(of word: String) -> String { (word as NSString).lastPathComponent }
}

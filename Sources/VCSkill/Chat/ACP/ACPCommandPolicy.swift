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

    // MARK: 自動モードでも、確認する

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
            case "curl": if rest.contains(where: { ["-d", "--data", "--data-binary", "--data-raw", "--data-urlencode", "-F", "--form", "-T", "--upload-file", "-X", "--request", "-K", "--config"].contains($0) || $0.hasPrefix("--data") || $0.hasPrefix("-d") && $0.count > 2 && !$0.hasPrefix("--") }) { return true }
            case "wget": if rest.contains(where: { $0.hasPrefix("--post") || $0 == "--method" || $0 == "--body-data" || $0 == "--body-file" }) { return true }
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
        "ssh", "scp", "sftp", "rsync", "nc", "ncat", "netcat", "telnet", "ftp", "mount", "umount", "hdiutil", "diskutil", "tmutil", "systemsetup", "scutil", "networksetup", "pmset", "security", "spctl", "csrutil", "dscl", "sysctl",
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

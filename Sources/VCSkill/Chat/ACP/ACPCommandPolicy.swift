import Foundation
import VCCore

/// 会話のエージェントが実行しようとする**コマンド**の、2 つの規則（**純粋**：シェルを動かさず、文字だけで見る）。自動モードの規則は `ACPAutoPolicy`、文字の切り分けは `ShellWords`。
/// - **断る**（`isCatastrophic`）：取り返しのつかない操作（ルート・ホーム・作業フォルダ・親フォルダの再帰削除、権限昇格、ディスクの消去、取ってきたものをシェルへ渡す…）。**段階・確認に関係なく**、断る（パネルも出さない）。
/// - **確認なしで許す**（`isHarmlessInFolder`）：作業フォルダの中の、一覧・日時・名前などを見るだけの、ごく小さな一組（`ls`・`pwd`・`date`・`whoami`・`uname`）。ファイルの**中身**を読むコマンドは、含めない。
/// どちらも、**網羅ではない**：文字を見る限りの、最小限の安全網（Zed の組み込みの拒否規則の考え方に倣った）。シェルの仕組み（変数・置換）を使った、回りくどい書き方は、見抜けない。
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
        return ShellWords.segments(of: command).contains { isCatastrophicSegment($0, home: home, depth: 0) }
    }

    private static let privilege: Set<String> = ["sudo", "doas", "su", "pkexec"]
    private static let machine: Set<String> = ["shutdown", "reboot", "halt", "mkfs", "newfs"]
    private static let systemRoots: Set<String> = ["/usr", "/etc", "/bin", "/sbin", "/System", "/Library", "/Users", "/Applications", "/var", "/private", "/opt", "/Volumes"]

    static func isCatastrophicSegment(_ segment: String, home: String, depth: Int) -> Bool {
        guard depth < 4 else { return false }
        let tokens = ShellWords.strippingWrappers(ShellWords.tokens(of: segment))
        guard let head = tokens.first else { return false }
        let command = ShellWords.name(of: head)
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
            if ShellWords.shells.contains(command), let c = rest.firstIndex(of: "-c"), c + 1 < rest.count {
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
}

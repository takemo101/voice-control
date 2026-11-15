import Foundation

// MARK: コマンドの歯止め（`all`）

/// モデルが頼んだコマンドを、**実行の前に**、コードで分ける：そのまま実行してよい・利用者に確認する・実行しない。**シェルは使わない**（`CommandPolicy.tokenize`）。
enum CommandGate {
    enum Decision: Equatable {
        case allow
        /// 利用者に確認する（理由）。
        case confirm(String)
        /// 実行しない（モデルへ返す理由）。
        case deny(String)
    }

    /// 確認なしで実行してよい：**読むだけ**の、よく使うコマンド（引数の場所が、作業フォルダの中のときだけ）。
    static let readOnly: Set<String> = ["ls", "pwd", "date", "cat", "head", "tail", "wc", "echo", "grep", "sort", "uniq", "diff", "file", "stat", "du", "which", "whoami", "uname", "sw_vers", "cal", "basename", "dirname"]

    /// 実行しない：シェル・別のコマンドを起動する・権限を上げる（`CommandPolicy.forbidden`）／インタプリタ（中身が見えない任意のコード）／外へ通信する／画面・アプリを動かす。
    static let denied: Set<String> = CommandPolicy.forbidden.union([
        "python", "python3", "node", "ruby", "perl", "php", "swift", "swiftc", "osascript", "osacompile", "lua", "deno", "bun",
        "curl", "wget", "ssh", "scp", "sftp", "nc", "ncat", "telnet", "ftp", "rsync", "dd", "mkfs", "diskutil", "launchctl", "defaults", "security", "killall", "kill", "shutdown", "reboot",
    ])

    static func classify(_ command: String, folder: URL) -> (argv: [String], decision: Decision) {
        guard case let .success(argv) = CommandPolicy.tokenize(command), let first = argv.first else { return ([], .deny("Could not parse the command (shell syntax such as pipes is not supported).")) }
        if first.contains("/") { return (argv, .deny("Use a command name without a path.")) }
        if denied.contains(first) { return (argv, .deny("\(first) is not allowed in this conversation (shells, interpreters, network and system commands are blocked).")) }
        if readOnly.contains(first) && argv.dropFirst().allSatisfy({ staysInside($0, folder: folder) }) { return (argv, .allow) }
        return (argv, .confirm(command))
    }

    /// 引数が、作業フォルダの中を指すか（パスに見えなければ、true）。`~`・フラグに含まれるパスは、確認へ回す。
    static func staysInside(_ argument: String, folder: URL) -> Bool {
        if argument.hasPrefix("-") { return !argument.contains("/") && !argument.contains("~") }
        guard argument.contains("/") || argument.hasPrefix("~") || argument == ".." || argument.hasPrefix("..") else { return true }
        if argument.hasPrefix("~") { return false }
        let realRoot = folder.resolvingSymlinksInPath().standardizedFileURL
        let url = argument.hasPrefix("/") ? URL(fileURLWithPath: argument) : realRoot.appendingPathComponent(argument)
        let real = url.resolvingSymlinksInPath().standardizedFileURL
        return real.path == realRoot.path || real.path.hasPrefix(realRoot.path + "/")
    }
}

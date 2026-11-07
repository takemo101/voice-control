import Foundation

/// 言語モデルが実行を頼むコマンドの、検査。**シェルは使わない**（パイプ・リダイレクト・`$()` は、ただの文字として、引数に渡る）。
/// スキルの `allowed-commands` に、先頭のトークン列が一致するものだけ、実行する。
public enum CommandPolicy {
    /// どのスキルも、許可できないコマンド（シェル・別のコマンドを起動する・権限を上げる）。
    public static let forbidden: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh", "env", "xargs", "sudo", "su", "doas", "eval", "exec", "nohup", "command", "builtin",
    ]

    public struct Violation: Error, Equatable { public let reason: String }

    /// シェルのような分け方：空白で区切る・`'…'` と `"…"` の中は、1 つ・`\` で、次の文字をそのまま。
    /// **例外：`"…"` の中の `\n`・`\t` は、改行・タブにする**（言語モデルは、Markdown など、複数行の文字を、`\n` と書いて渡す。そのままだと、`\` が落ちて、`n` になる。シェルは使わないので、安全面は、変わらない）。
    public static func tokenize(_ s: String) -> Result<[String], Violation> {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for ch in s {
            if escaped {
                // `"…"` の中だけ、`\n`・`\t` を、改行・タブに
                if quote == "\"" && ch == "n" { current.append("\n") } else if quote == "\"" && ch == "t" { current.append("\t") } else { current.append(ch) }
                escaped = false; inToken = true; continue
            }
            if ch == "\\" && quote != "'" { escaped = true; inToken = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; inToken = true; continue }
            if ch == " " || ch == "\t" {
                if inToken { tokens.append(current); current = ""; inToken = false }
                continue
            }
            current.append(ch); inToken = true
        }
        if quote != nil { return .failure(Violation(reason: "引用符が閉じていない")) }
        if escaped { return .failure(Violation(reason: "末尾が \\ で終わっている")) }
        if inToken { tokens.append(current) }
        return .success(tokens)
    }

    /// 項目の書き方の正規化。Claude Code の権限ルールの形も受ける：
    /// - `Bash(open -a *)` → `open -a *`（`Bash(…)` の包みを外す。`Bash` 以外のツール名は不可）
    /// - 末尾の `:*`（古い書き方）→ 末尾の `*`
    /// - 末尾の `*` だけのトークンは、外す（前方一致なので、もともと、後ろの引数は何でも通る）
    /// 戻り値は、照合に使うトークン列。解釈できなければ、理由。
    public static func normalize(_ entry: String) -> Result<[String], Violation> {
        var text = entry.trimmingCharacters(in: .whitespaces)
        if let open = text.firstIndex(of: "("), text.hasSuffix(")") {
            let tool = String(text[..<open])
            guard tool == "Bash" else { return .failure(Violation(reason: "ツール名は Bash だけ（\(tool.isEmpty ? "なし" : tool)）")) }
            text = String(text[text.index(after: open)..<text.index(before: text.endIndex)]).trimmingCharacters(in: .whitespaces)
        }
        if text.hasSuffix(":*") { text = String(text.dropLast(2)) }
        guard case .success(var tokens) = tokenize(text) else { return .failure(Violation(reason: "解釈できない（引用符・\\ の閉じ忘れ）")) }
        while tokens.last == "*" { tokens.removeLast() }
        guard !tokens.isEmpty else { return .failure(Violation(reason: "空")) }
        return .success(tokens)
    }

    /// `*` が、任意の文字列（空を含む）に一致する、トークン 1 つの照合。
    static func globMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        // 動的計画法：match[i][j] = p[..<i] が t[..<j] に一致
        var match = Array(repeating: Array(repeating: false, count: t.count + 1), count: p.count + 1)
        match[0][0] = true
        for i in stride(from: 1, through: p.count, by: 1) { match[i][0] = match[i - 1][0] && p[i - 1] == "*" }
        for i in stride(from: 1, through: p.count, by: 1) {
            for j in stride(from: 1, through: t.count, by: 1) {
                match[i][j] = p[i - 1] == "*" ? (match[i - 1][j] || match[i][j - 1]) : (match[i - 1][j - 1] && p[i - 1] == t[j - 1])
            }
        }
        return match[p.count][t.count]
    }

    /// 項目のトークン列が、コマンドの先頭のトークン列に一致するか。トークンに `*` があれば、そのトークンの中で、任意の文字列に一致する（トークンをまたがない）。`*` だけのトークンは、任意の 1 トークン。
    static func matches(prefix: [String], argv: [String]) -> Bool {
        guard argv.count >= prefix.count else { return false }
        return zip(prefix, argv).allSatisfy { pattern, token in pattern.contains("*") ? globMatch(pattern, token) : pattern == token }
    }

    /// `allowed-commands` の 1 項目の検査。不正なら、理由。
    public static func validateEntry(_ entry: String) -> String? {
        let tokens: [String]
        switch normalize(entry) {
        case .failure(let v): return v.reason
        case .success(let t): tokens = t
        }
        let first = tokens[0]
        if first.contains("*") { return "コマンド名に * は使えない（どのコマンドにも一致してしまう）" }
        if first.contains("/") { return "コマンド名にパスは使えない（PATH の名前だけ）" }
        if first.range(of: "^[A-Za-z0-9._+-]+$", options: .regularExpression) == nil { return "コマンド名に使えない文字がある" }
        if forbidden.contains(first) { return "\(first) は、許可できない（シェル・別のコマンドを起動する・権限を上げる）" }
        return nil
    }

    /// 言語モデルが、許可の先頭（`osascript /…/spotify.applescript`）を**落として**、動作と引数だけ（`volume 50`）を書いたとき、許可の先頭を前に付けて補う。
    /// 補うのは、次のすべてに当てはまるときだけ（「先頭を書き忘れた」と言える形に限る）：
    /// - 許可が **1 項目**で、**インタプリタ + スクリプトのパス**（`osascript /…/x.applescript`・`node /…/x.mjs`）の形。
    /// - コマンドの先頭が、許可のプログラムと**違う**（`osascript` で始まっていれば、書き忘れでなく、許可にない書き方）。
    /// - 先頭が、シェルなどの許可できない名前でも、パスでもなく、**PATH にある実在のコマンドでもない**（`rm`・`open`・`curl` は、別のコマンドを頼んでいるので、補わず、拒否のまま）。
    /// 補っても、許可の先頭 + 言語モデルの引数で、引数を言語モデルが決められることは、補う前と同じ：権限は、広がらない。補ったあとも、`check` を通す。補えなければ nil。
    public static func completed(command: String, argv: [String], allowed: [String]) -> (command: String, argv: [String])? {
        guard allowed.count == 1, case let .success(entry) = normalize(allowed[0]), entry.count >= 2, entry[entry.count - 1].hasPrefix("/"),
              let first = argv.first, first != entry[0], !first.contains("/"), !forbidden.contains(first), !isExecutableOnPath(first),
              check(argv: argv, allowed: allowed) != nil else { return nil }
        let full = allowed[0] + " " + command
        guard case .success(let completed) = tokenize(full), check(argv: completed, allowed: allowed) == nil else { return nil }
        return (full, completed)
    }

    /// その名前の実行ファイルが、PATH にあるか。
    static func isExecutableOnPath(_ name: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    /// 実行してよいか。許可なら `nil`、拒否なら理由。
    public static func check(argv: [String], allowed: [String]) -> Violation? {
        guard let first = argv.first else { return Violation(reason: "コマンドが空") }
        if first.contains("/") { return Violation(reason: "パスでの指定は不可（\(first)）。コマンド名だけ") }
        if forbidden.contains(first) { return Violation(reason: "\(first) は、許可できない") }
        if argv.contains(where: { $0.contains("\0") }) { return Violation(reason: "引数に、使えない文字がある") }
        // agent-desktop の、危険なキー（アプリの終了など）の保護を、外す指定は不可。
        if first == "agent-desktop", argv.contains("--force") { return Violation(reason: "agent-desktop --force は不可") }
        let permitted = allowed.contains { entry in
            guard case .success(let prefix) = normalize(entry) else { return false }
            return matches(prefix: prefix, argv: argv)
        }
        return permitted ? nil : Violation(reason: "このスキルでは許可されていない（許可：\(allowed.joined(separator: "、"))）")
    }
}

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
    public static func tokenize(_ s: String) -> Result<[String], Violation> {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; inToken = true; continue }
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

    /// `allowed-commands` の 1 項目の検査。不正なら、理由。
    public static func validateEntry(_ entry: String) -> String? {
        guard case .success(let tokens) = tokenize(entry), let first = tokens.first else { return "空、または、解釈できない" }
        if first.contains("/") { return "コマンド名にパスは使えない（PATH の名前だけ）" }
        if first.range(of: "^[A-Za-z0-9._+-]+$", options: .regularExpression) == nil { return "コマンド名に使えない文字がある" }
        if forbidden.contains(first) { return "\(first) は、許可できない（シェル・別のコマンドを起動する・権限を上げる）" }
        return nil
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
            guard case .success(let prefix) = tokenize(entry), !prefix.isEmpty, argv.count >= prefix.count else { return false }
            return Array(argv.prefix(prefix.count)) == prefix
        }
        return permitted ? nil : Violation(reason: "このスキルでは許可されていない（許可：\(allowed.joined(separator: "、"))）")
    }
}

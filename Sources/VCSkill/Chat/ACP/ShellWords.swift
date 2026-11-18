import Foundation

/// コマンドの文字を、シェルを動かさずに、切り分ける（**純粋**）。`ACPCommandPolicy`（断る・読むだけ）と `ACPAutoPolicy`（自動モード）が使う。
/// **区切りすぎは、断る側では見落とさず、許す側では判断しないので、安全側**（引用の中も、区切る）。
enum ShellWords {
    /// 先頭に付いて、別のコマンドを動かすもの（`env`・`nohup`・`time`…）。見るのは、その中身。
    static let wrappers: Set<String> = ["env", "command", "nohup", "time", "nice", "exec", "builtin", "caffeinate"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// `;`・`&&`・`||`・`|`・`&`・改行で、区切る。括弧は、外す。
    static func segments(of command: String) -> [String] {
        command.components(separatedBy: CharacterSet(charactersIn: ";&|\n\r")).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "({ \t)}")) }.filter { !$0.isEmpty }
    }

    /// 空白で区切った語（引用符・逆スラッシュは外す）。
    static func words(_ segment: String) -> [String] {
        segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.filter { $0 != "'" && $0 != "\"" && $0 != "\\" } }.filter { !$0.isEmpty }
    }

    static func name(of word: String) -> String { (word as NSString).lastPathComponent }

    /// 1 つの区切りの語。先頭の変数の代入（`FOO=bar cmd`）は、除く。
    static func tokens(of segment: String) -> [String] {
        var tokens = words(segment)
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-"), !first.hasPrefix("=") { tokens.removeFirst() }
        return tokens
    }

    /// 先頭のラッパー（`env`・`nohup`…）を、除く。
    static func strippingWrappers(_ tokens: [String]) -> [String] {
        var tokens = tokens
        while let first = tokens.first, wrappers.contains(name(of: first)) { tokens.removeFirst() }
        return tokens
    }
}

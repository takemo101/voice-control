import Foundation
import VCCore

/// 長いコマンドの、**確認用の要約**（**純粋**）：何を実行するのかが、ひと目で分かるように、**1 行の見出し**（何のプログラムで・何をするか・どのファイルへ）と、**短い抜粋**に分ける。
/// 例：`python3 -c 'from pathlib import Path; Path("a.md").open("x").write("""…長い本文…""")'` → 見出し「python3 のコードを実行：a.md を新しく作る（全 790 文字）」・抜粋「python3 -c 'from pathlib import Path; …（残り 650 文字は、略しています）」。
/// 短いコマンドは、そのまま（要約しない）。**取り返しのつかないコマンドの判断は、全文で行う**（`ACPCommandPolicy`）：ここは、見せ方だけ。全文は、会話の「実行した操作」に残る。
enum ACPCommandSummary {
    struct Summary: Equatable {
        /// 1 行の見出し（読み上げにも使う）。
        let headline: String
        /// 抜粋（短いコマンドでは、空）。
        let preview: String
    }

    /// この長さ（空白をまとめたあと）までは、そのまま見せる。
    static let shortLimit = 100
    /// 抜粋の長さ。
    static let previewLimit = 140

    /// `collapsed`：見えない文字を直し、改行・空白をまとめた、コマンド全体。
    static func summarize(_ collapsed: String) -> Summary {
        let text = collapsed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard text.count > shortLimit else { return Summary(headline: text, preview: "") }
        let program = programName(of: text)
        let kind = isInterpreter(program) ? tr("\(program) のコードを実行") : (shellKeywords.contains(program) ? tr("シェルのスクリプトを実行") : tr("\(program) を実行"))
        var headline = kind
        let writes = writtenFiles(in: text)
        if !writes.isEmpty {
            let list = writes.prefix(3).map { tr("\($0.file) を\($0.verb)") }.joined(separator: tr("・")) + (writes.count > 3 ? tr(" ほか") : "")
            headline = tr("\(kind)：\(list)")
        }
        headline = tr("\(headline)（全 \(text.count) 文字）")
        let preview = text.count > previewLimit ? tr("\(String(text.prefix(previewLimit)))…（残り \(text.count - previewLimit) 文字は、略しています）") : text
        return Summary(headline: headline, preview: preview)
    }

    // MARK: 部品

    /// シェルの構文の語（`if [ -e a ]; then …`：プログラムの名前では、ない）。
    static let shellKeywords: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "[", "[[", "!", "{", "function"]
    static let interpreters: Set<String> = ["python", "python3", "node", "deno", "bun", "ruby", "perl", "php", "osascript", "sh", "bash", "zsh", "swift"]
    static func isInterpreter(_ program: String) -> Bool { interpreters.contains(program) }

    /// 実行するプログラム：先頭の `cd … &&`・`set -…;`・`(`・`env`・`time` などを飛ばした、最初の語の名前（パスの最後）。
    static func programName(of command: String) -> String {
        var rest = Substring(command)
        for _ in 0..<6 {
            rest = rest.drop(while: { $0 == " " || $0 == "(" || $0 == "{" })
            let word = rest.prefix(while: { $0 != " " })
            if word == "cd" || word == "set" || word == "export" || word == "unset" || word == "env" || word == "time" || word == "exec" || word == "nohup" || word == "command" {
                // 次の区切り（`&&`・`;`）まで飛ばす（`env`・`time`・`exec` は、その語だけ）
                if ["env", "time", "exec", "nohup", "command"].contains(String(word)) { rest = rest.dropFirst(word.count); continue }
                if let range = rest.range(of: #"\s*(&&|;)\s*"#, options: .regularExpression) { rest = rest[range.upperBound...]; continue }
                break
            }
            // `FOO=bar cmd` の、変数の指定を飛ばす
            if word.contains("="), !word.hasPrefix("="), word.firstIndex(of: "=").map({ word[..<$0].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }) == true { rest = rest.dropFirst(word.count); continue }
            break
        }
        let word = rest.prefix(while: { $0 != " " && $0 != ";" && $0 != "&" && $0 != "|" })
        let name = String(word.split(separator: "/").last ?? word).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return name.isEmpty ? tr("コマンド") : name
    }

    /// 書き込む先のファイル（コードの中の `open("名前", "モード")`・`Path("名前").write_text`・シェルの `>`・`>>`・`tee`）と、やり方（新しく作る・上書き・追記）。**見つかったものだけ**（見つからなくても、実行の内容は、変わらない：抜粋で確かめられる）。
    static func writtenFiles(in command: String) -> [(file: String, verb: String)] {
        var found: [(String, String)] = []
        func add(_ file: String, _ verb: String) {
            guard !file.isEmpty, file.count <= 80, !file.hasPrefix("&"), file != "/dev/null", !found.contains(where: { $0.0 == file }) else { return }
            found.append((file, verb))
        }
        func matches(_ pattern: String, _ body: ([String]) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = command as NSString
            for match in regex.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
                body((0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) })
            }
        }
        func verb(forMode mode: String) -> String { mode.contains("x") ? tr("新しく作る") : (mode.contains("a") ? tr("追記する") : tr("書き込む")) }
        // python：open("名前", "x") / .open("x") の前の Path("名前")
        matches(#"open\(\s*["']([^"']+)["']\s*,\s*(?:mode\s*=\s*)?["']([rwaxb+]+)["']"#) { add($0[1], verb(forMode: $0[2])) }
        matches(#"Path\(\s*["']([^"']+)["']\s*\)\s*\.open\(\s*["']([rwaxb+]+)["']"#) { add($0[1], verb(forMode: $0[2])) }
        matches(#"Path\(\s*["']([^"']+)["']\s*\)\s*\.write_(?:text|bytes)\("#) { add($0[1], tr("書き込む")) }
        // シェル：> 名前・>> 名前・tee 名前（`2>&1`・`>&2`・`/dev/null` は除く）
        matches(#"(?<![0-9&>])(>>?)\s*["']?([A-Za-z0-9_./~\-][^\s"'|;&<>)]*)"#) { add($0[2], $0[1] == ">>" ? tr("追記する") : tr("書き込む")) }
        matches(#"\btee\s+(-a\s+)?["']?([A-Za-z0-9_./~\-][^\s"'|;&<>)]*)"#) { add($0[2], $0[1].isEmpty ? tr("書き込む") : tr("追記する")) }
        return found
    }
}

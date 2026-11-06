import AppKit
import Foundation

/// コードブロックの色づけ（Markdown のウィンドウ）。言語ごとの字句解析ではなく、**コメント・文字列・数・キーワード・型・（JSON の）キー・シェルのオプション**を、言語ごとの小さな表で見分ける。
/// 言語が分からない（書いていない・知らない）ときは、色をつけない（間違った色よりよい）。外部のライブラリは使わない。
enum CodeHighlighter {
    enum Kind: Equatable { case comment, string, number, keyword, type, key, option }

    struct Token: Equatable {
        var range: NSRange
        var kind: Kind
    }

    /// 言語ごとの表。
    struct Language {
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: [Character] = ["\"", "'"]
        var keywords: Set<String> = []
        /// 大文字で始まる語を、型の色にする。
        var capitalizedTypes = false
        /// `-x`・`--long` を、オプションの色にする（シェル）。
        var options = false
        /// `"キー":` を、キーの色にする（JSON）。
        var jsonKeys = false
        /// `$NAME`・`${NAME}` を、キーワードの色にする（シェル）。
        var variables = false
        /// キーワードの大文字小文字を区別しない（SQL）。
        var caseInsensitive = false
    }

    private static let cLike: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "true", "false", "null", "nil", "new", "this", "self", "super", "static", "const", "let", "var", "func", "function", "class", "struct", "enum", "interface", "protocol", "extension", "import", "export", "from", "as", "in", "is", "try", "catch", "throw", "throws", "async", "await", "public", "private", "protected", "internal", "final", "override", "init", "guard", "where", "typealias", "extends", "implements", "package", "void", "int", "bool", "string", "undefined", "typeof", "yield", "fn", "pub", "mut", "impl", "trait", "use", "mod", "match", "loop", "go", "defer", "chan", "map", "range", "fun", "val", "object", "when", "of", "type"]

    private static let languages: [String: Language] = {
        let swift = Language(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: cLike, capitalizedTypes: true)
        let js = Language(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], keywords: cLike, capitalizedTypes: true)
        let c = Language(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: cLike, capitalizedTypes: true)
        let python = Language(lineComments: ["#"], keywords: ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "in", "is", "not", "and", "or", "None", "True", "False", "async", "await", "global", "nonlocal", "del", "assert", "self"], capitalizedTypes: true)
        let shell = Language(lineComments: ["#"], keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "exit", "export", "local", "readonly", "source", "alias", "unset", "set", "echo", "cd", "true", "false"], options: true, variables: true)
        let json = Language(quotes: ["\""], keywords: ["true", "false", "null"], jsonKeys: true)
        let yaml = Language(lineComments: ["#"], keywords: ["true", "false", "null", "yes", "no", "on", "off"], jsonKeys: false)
        let sql = Language(lineComments: ["--"], blockComment: ("/*", "*/"), keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "distinct", "union", "null", "is", "in", "like", "between", "case", "when", "then", "else", "end", "primary", "key", "index", "unique", "default", "count", "sum", "avg", "min", "max"], caseInsensitive: true)
        let css = Language(blockComment: ("/*", "*/"), keywords: [])
        let ruby = Language(lineComments: ["#"], keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "require", "include", "nil", "true", "false", "self", "then", "case", "when", "puts"], capitalizedTypes: true)
        var table: [String: Language] = [:]
        for name in ["swift"] { table[name] = swift }
        for name in ["js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "java", "kotlin", "kt", "scala", "dart", "go", "golang", "rust", "rs", "php"] { table[name] = js }
        for name in ["c", "cpp", "c++", "cc", "h", "hpp", "objc", "objective-c", "m", "cs", "csharp", "c#"] { table[name] = c }
        for name in ["py", "python", "python3"] { table[name] = python }
        for name in ["sh", "bash", "zsh", "shell", "console", "fish", "ksh", "terminal"] { table[name] = shell }
        for name in ["json", "jsonc", "json5"] { table[name] = json }
        for name in ["yaml", "yml", "toml", "ini", "conf", "dockerfile", "makefile", "make"] { table[name] = yaml }
        for name in ["sql", "mysql", "postgres", "postgresql", "sqlite"] { table[name] = sql }
        for name in ["css", "scss", "less"] { table[name] = css }
        for name in ["rb", "ruby"] { table[name] = ruby }
        return table
    }()

    /// 言語の名前（コードブロックの先頭に書く語。大文字小文字・前後の空白・`{…}` などの付記は、無視）から、表を引く。知らなければ nil。
    static func language(named name: String?) -> Language? {
        guard let name else { return nil }
        let key = name.lowercased().split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init) ?? ""
        return languages[key]
    }

    /// 色をつける範囲（`text` の中の位置。UTF-16）。重ならない。
    static func tokens(in text: String, language: Language) -> [Token] {
        let s = Array(text.utf16)
        var tokens: [Token] = []
        var i = 0
        let n = s.count
        func scalar(_ c: Character) -> UInt16 { c.utf16.first ?? 0 }
        func matches(_ prefix: String, at index: Int) -> Bool {
            let p = Array(prefix.utf16)
            return index + p.count <= n && Array(s[index..<index + p.count]) == p
        }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80 }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
        let quoteSet = Set(language.quotes.map(scalar))
        while i < n {
            let c = s[i]
            // コメント
            if let comment = language.lineComments.first(where: { matches($0, at: i) }) {
                // シェルの `#` は、語の途中（`$#`・`a#b`）では、コメントではない
                let startsWord = i == 0 || s[i - 1] == 32 || s[i - 1] == 9 || s[i - 1] == 10
                if comment != "#" || startsWord || !language.options {
                    var j = i
                    while j < n && s[j] != 10 { j += 1 }
                    tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .comment)); i = j; continue
                }
            }
            if let block = language.blockComment, matches(block.open, at: i) {
                var j = i + block.open.utf16.count
                while j < n && !matches(block.close, at: j) { j += 1 }
                j = min(n, j + block.close.utf16.count)
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .comment)); i = j; continue
            }
            // 文字列（行をまたがない：閉じ忘れの色が、後ろへ広がらない。`` ` `` は、またげる）
            if quoteSet.contains(c) {
                let quote = c
                var j = i + 1
                while j < n {
                    if s[j] == 92 { j += 2; continue }   // バックスラッシュ
                    if s[j] == quote { j += 1; break }
                    if s[j] == 10, quote != 96 { break }
                    j += 1
                }
                j = min(j, n)
                // JSON のキー：文字列のあとに `:` が続く
                var isKey = false
                if language.jsonKeys {
                    var k = j
                    while k < n && (s[k] == 32 || s[k] == 9) { k += 1 }
                    isKey = k < n && s[k] == 58
                }
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: isKey ? .key : .string)); i = j; continue
            }
            // シェルの変数
            if language.variables, c == 36, i + 1 < n, isIdentStart(s[i + 1]) || s[i + 1] == 123 {
                var j = i + 1
                if s[j] == 123 { while j < n && s[j] != 125 && s[j] != 10 { j += 1 }; j = min(n, j + 1) } else { while j < n && isIdent(s[j]) { j += 1 } }
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .keyword)); i = j; continue
            }
            // シェルのオプション（語の頭の `-x`・`--long`）
            if language.options, c == 45, i == 0 || s[i - 1] == 32 || s[i - 1] == 9 || s[i - 1] == 10, i + 1 < n, s[i + 1] == 45 || isIdentStart(s[i + 1]) {
                var j = i + 1
                while j < n && (isIdent(s[j]) || s[j] == 45 || s[j] == 61) { j += 1 }
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .option)); i = j; continue
            }
            // 数
            if isDigit(c), i == 0 || !isIdent(s[i - 1]) {
                var j = i + 1
                while j < n && (isIdent(s[j]) || s[j] == 46 && j + 1 < n && isDigit(s[j + 1])) { j += 1 }
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .number)); i = j; continue
            }
            // 語（キーワード・型）
            if isIdentStart(c) {
                var j = i + 1
                while j < n && isIdent(s[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(s[i..<j]), count: j - i)
                let isKeyword = language.caseInsensitive ? language.keywords.contains(word.lowercased()) : language.keywords.contains(word)
                if isKeyword {
                    tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .keyword))
                } else if language.capitalizedTypes, let first = word.unicodeScalars.first, first.properties.isUppercase, word != word.uppercased() {
                    tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .type))   // 大文字だけの語（定数）は、型にしない
                }
                i = j; continue
            }
            i += 1
        }
        return tokens
    }

    /// 暗いガラスの上の、色。
    static func color(for kind: Kind) -> NSColor {
        switch kind {
        case .comment: return NSColor(white: 1, alpha: 0.42)
        case .string: return NSColor(calibratedRed: 0.62, green: 0.86, blue: 0.58, alpha: 1)
        case .number: return NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.45, alpha: 1)
        case .keyword: return NSColor(calibratedRed: 1.0, green: 0.56, blue: 0.74, alpha: 1)
        case .type: return NSColor(calibratedRed: 0.52, green: 0.84, blue: 0.92, alpha: 1)
        case .key: return NSColor(calibratedRed: 0.55, green: 0.78, blue: 1.0, alpha: 1)
        case .option: return NSColor(calibratedRed: 0.78, green: 0.70, blue: 1.0, alpha: 1)
        }
    }
}

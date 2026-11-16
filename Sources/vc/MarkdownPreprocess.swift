import Foundation

/// Markdown の解析の前に、**そのまま出すと読みにくいもの**を、読める形に直す（`MarkdownRenderer.pieces`）。コードブロック・コード片の中は、触らない。
/// - **数式**（`$…$`・`$$…$$`）：LaTeX の記号を、Unicode の記号に直す（`\\alpha`→α・`\\frac{a}{b}`→(a)/(b)・`x^2`→x²・`\\sum`→∑…）。**組版ではない**（分数の段組み・根号の線などは、できない）：読める文字にするだけ。
///   行の中の `$…$` は、**数式らしいときだけ**（`\\` の記号・`^`・`_`・`{}` を含み、前後に空白がない）。「$5 と $10」のような金額は、触らない。ブロックは、等幅のブロックにする。
/// - **`<details>`**：`<summary>` を太字の行にして、タグを外す（折りたたみは、できない：全部、出す）。
enum MarkdownPreprocess {
    static func apply(_ markdown: String) -> String {
        guard markdown.contains("$") || markdown.contains("<details") || markdown.contains("<summary") else { return markdown }
        var out: [String] = []
        var inFence = false
        var blockMath: [String]? = nil
        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if blockMath == nil, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); out.append(rawLine); continue }
            if inFence { out.append(rawLine); continue }
            // ブロックの数式（`$$` で始まり、`$$` で終わる。1 行でも、複数行でも）
            if var collected = blockMath {
                if let end = trimmed.range(of: "$$") {
                    let before = String(trimmed[..<end.lowerBound])
                    if !before.isEmpty { collected.append(before) }
                    out.append(contentsOf: mathBlock(collected)); blockMath = nil
                    let after = String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty { out.append(after) }
                } else { collected.append(trimmed); blockMath = collected }
                continue
            }
            if trimmed.hasPrefix("$$") {
                let body = String(trimmed.dropFirst(2))
                if let end = body.range(of: "$$") {
                    out.append(contentsOf: mathBlock([String(body[..<end.lowerBound])]))
                    let after = String(body[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty { out.append(after) }
                } else { blockMath = body.isEmpty ? [] : [body] }
                continue
            }
            out.append(details(inlineMath(rawLine)))
        }
        if let collected = blockMath { out.append(contentsOf: mathBlock(collected)) }   // 閉じ忘れ：そこまでを、ブロックにする
        return out.joined(separator: "\n")
    }

    // MARK: ブロックの数式

    private static func mathBlock(_ lines: [String]) -> [String] {
        let text = lines.map { LaTeXText.convert($0) }.filter { !$0.isEmpty }
        return ["", "```math"] + (text.isEmpty ? [""] : text) + ["```", ""]
    }

    // MARK: 行の中の数式（コード片の外だけ）

    private static func inlineMath(_ line: String) -> String {
        guard line.contains("$") else { return line }
        // バッククォートで、コード片（と、そうでない部分）に分ける
        var result = ""
        var plain = ""
        var inCode = false
        var code = ""
        for ch in line {
            if ch == "`" {
                if inCode { result += plain.isEmpty ? "" : convertInline(plain); plain = ""; result += "`" + code + "`"; code = ""; inCode = false }
                else { result += convertInline(plain); plain = ""; inCode = true }
                continue
            }
            if inCode { code.append(ch) } else { plain.append(ch) }
        }
        if inCode { result += "`" + code }   // 閉じていない
        result += convertInline(plain)
        return result
    }

    private static func convertInline(_ text: String) -> String {
        guard text.contains("$") else { return text }
        var out = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "$" { out.append("$"); i += 2; continue }   // `\$`：金額の `$`
            if chars[i] == "$" {
                // 閉じる `$`（逆スラッシュで逃がしたものは、除く）を探す
                var j = i + 1
                while j < chars.count, !(chars[j] == "$" && chars[j - 1] != "\\") { j += 1 }
                if j < chars.count {
                    let body = String(chars[(i + 1)..<j])
                    if looksLikeMath(body) { out += LaTeXText.convert(body); i = j + 1; continue }
                }
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    /// 数式らしいか：前後に空白がなく、LaTeX の記号（`\\`・`^`・`_`・`{`）を含む。「$5 と $10」は、違う。
    private static func looksLikeMath(_ body: String) -> Bool {
        guard let first = body.first, let last = body.last, !first.isWhitespace, !last.isWhitespace, body.count <= 200 else { return false }
        return body.contains("\\") || body.contains("^") || body.contains("_") || body.contains("{")
    }

    // MARK: <details>

    private static func details(_ line: String) -> String {
        guard line.contains("<details") || line.contains("</details") || line.contains("<summary") || line.contains("</summary") else { return line }
        var text = line
        text = text.replacingOccurrences(of: #"<summary[^>]*>(.*?)</summary>"#, with: "**$1**  \n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?(details|summary)[^>]*>"#, with: "", options: .regularExpression)
        return text
    }
}

/// LaTeX の数式を、**読める Unicode の文字**に直す（組版ではない）。知らない記号は、そのまま残す。
enum LaTeXText {
    static func convert(_ latex: String) -> String {
        var s = latex
        s = s.replacingOccurrences(of: #"\\(left|right|big|Big|bigg|Bigg)\b\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(,|;|:|!|quad|qquad)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\", with: "\n")   // 行の区切り（`\\`）
        s = replaceCommand(s, name: "text", transform: { $0 })
        for name in ["mathrm", "mathbf", "mathit", "operatorname", "textbf", "textit", "mathcal", "boldsymbol", "vec", "hat", "bar", "overline"] { s = replaceCommand(s, name: name, transform: { $0 }) }
        s = replaceCommand(s, name: "mathbb", transform: { $0.map { blackboard[$0] ?? String($0) }.joined() })
        s = replaceCommand(s, name: "sqrt", transform: { "√(\($0))" })
        s = replaceFractions(s)
        // 記号（長い名前から）
        for (name, symbol) in symbols.sorted(by: { $0.key.count > $1.key.count }) {
            s = s.replacingOccurrences(of: #"\\"# + name + #"(?![A-Za-z])"#, with: NSRegularExpression.escapedTemplate(for: symbol), options: .regularExpression)
        }
        s = scripts(s)
        s = s.replacingOccurrences(of: #"\\([{}%&#_$])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `\name{…}` を、中身を変換して置き換える（入れ子の `{}` に対応）。
    private static func replaceCommand(_ text: String, name: String, transform: (String) -> String) -> String {
        var result = text
        let marker = "\\" + name
        while let range = result.range(of: marker + "{") ?? result.range(of: marker + " {") {
            let open = result.index(range.upperBound, offsetBy: -1)
            guard let (body, end) = braced(result, from: open) else { break }
            result.replaceSubrange(range.lowerBound..<end, with: transform(body))
        }
        return result
    }

    /// `\frac{a}{b}` → `(a)/(b)`（1 文字・1 つの数なら、括弧なし）。
    private static func replaceFractions(_ text: String) -> String {
        var result = text
        while let range = result.range(of: #"\\[dt]?frac\s*\{"#, options: .regularExpression) {
            let open = result.index(range.upperBound, offsetBy: -1)
            guard let (numerator, afterNumerator) = braced(result, from: open),
                  afterNumerator < result.endIndex, let secondOpen = result[afterNumerator...].firstIndex(where: { !$0.isWhitespace }), result[secondOpen] == "{",
                  let (denominator, end) = braced(result, from: secondOpen) else { break }
            func wrap(_ x: String) -> String { x.count <= 1 || x.allSatisfy({ $0.isNumber }) ? x : "(\(x))" }
            result.replaceSubrange(range.lowerBound..<end, with: wrap(numerator) + "/" + wrap(denominator))
        }
        return result
    }

    /// `{` から、対応する `}` までの中身と、その次の位置。
    private static func braced(_ text: String, from open: String.Index) -> (String, String.Index)? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" { depth -= 1; if depth == 0 { return (String(text[text.index(after: open)..<index]), text.index(after: index)) } }
            index = text.index(after: index)
        }
        return nil
    }

    /// 上付き・下付き（`x^2`・`x^{10}`・`a_i`・`a_{ij}`）：Unicode の添え字にできるときは、それに。できなければ、`^(…)`・`_(…)`。
    private static func scripts(_ text: String) -> String {
        var result = text
        for (marker, table) in [("^", superscripts), ("_", subscripts)] {
            let pattern = #"\"# + marker + #"(\{[^{}]*\}|[A-Za-z0-9+\-])"#
            while let range = result.range(of: pattern, options: .regularExpression) {
                var body = String(result[range].dropFirst())
                if body.hasPrefix("{") { body = String(body.dropFirst().dropLast()) }
                let mapped = body.map { table[$0] }
                result.replaceSubrange(range, with: mapped.allSatisfy({ $0 != nil }) ? mapped.compactMap { $0 }.map(String.init).joined() : "\(marker)(\(body))")
            }
        }
        return result
    }

    private static let superscripts: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "T": "ᵀ"]
    private static let subscripts: [Character: Character] = ["0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋", "i": "ᵢ", "j": "ⱼ", "n": "ₙ", "x": "ₓ", "k": "ₖ", "m": "ₘ"]
    private static let blackboard: [Character: String] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ"]

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "sum": "∑", "prod": "∏", "int": "∫", "oint": "∮", "partial": "∂", "nabla": "∇", "infty": "∞", "sqrt": "√",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝", "ll": "≪", "gg": "≫",
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "·", "ast": "∗", "circ": "∘", "bullet": "•", "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⇒", "iff": "⇔", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
        "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "cup": "∪", "cap": "∩", "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨", "wedge": "∧", "vee": "∨",
        "angle": "∠", "perp": "⊥", "parallel": "∥", "degree": "°", "prime": "′", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
        "sin": "sin", "cos": "cos", "tan": "tan", "log": "log", "ln": "ln", "exp": "exp", "lim": "lim", "max": "max", "min": "min", "det": "det", "arg": "arg",
    ]
}

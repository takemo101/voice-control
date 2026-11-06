import AppKit
import Foundation

/// Markdown を、整形した `NSAttributedString`（と、コピー用の文字）にする（`vc show`・`result: markdown-window` のウィンドウ）。
/// Foundation の Markdown 解析（`AttributedString(markdown:)`）の結果を、見やすく整える：見出しの階層・読みやすい行間・箇条書きと番号・タスクリスト・引用（左の線）・コードブロック（面）・表（罫線）・区切り線。外部のライブラリは使わない。
/// 色は、暗いガラスの背景（`HUDStyle`）に合わせた、白系と、アクセント（ティール）。
enum MarkdownRenderer {
    // MARK: 入口

    /// 整形した文章。解析できなければ、元の文字をそのまま。
    @MainActor static func render(_ markdown: String) -> NSAttributedString {
        let pieces = Self.pieces(markdown)
        guard !pieces.isEmpty else { return NSAttributedString(string: markdown, attributes: [.font: bodyFont, .foregroundColor: HUDStyle.primary]) }
        let out = NSMutableAttributedString()
        var current: Int?
        var lastAttributes: [NSAttributedString.Key: Any] = [:]
        let context = Context(tableWidths: columnWidths(of: pieces))
        var lastPanel: Int?
        var lastItem: Int?
        for piece in pieces {
            // 箇条書きの項目の、2 つ目以降の段落・コードブロックには、行頭の記号を付けない（字下げだけ）
            let continuation = piece.block.listDepth > 0 && piece.block.itemIdentity != nil && piece.block.itemIdentity == lastItem
            if piece.block.identity != current {
                // 段落の区切り（直前の段落の見た目を引き継ぐ：表のセルや、引用の面が、途切れない）
                if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: lastAttributes)) }
                // 表・コードブロックの面の後ろには、小さな空きを入れる（面は、次の段落に、くっついて見える）
                if let lastPanel, lastPanel != piece.block.panelKey { out.append(Self.spacer()) }
                lastPanel = piece.block.panelKey
                current = piece.block.identity
                // タスクリストは、箇条書きの「•」ではなく、☐・☑ だけ
                if let prefix = piece.block.prefix, !continuation, !Self.isTask(piece) {
                    out.append(NSAttributedString(string: prefix, attributes: Self.attributes(for: piece.block, inline: nil, link: nil, text: "", context: context, marker: true, continuation: false)))
                }
                lastItem = piece.block.listDepth > 0 ? piece.block.itemIdentity : nil
            }
            let text = Self.cleaned(piece)
            let attrs = Self.attributes(for: piece.block, inline: piece.inline, link: piece.link, text: text, context: context, marker: false, continuation: continuation)
            out.append(NSAttributedString(string: text, attributes: attrs))
            lastAttributes = Self.attributes(for: piece.block, inline: nil, link: nil, text: "", context: context, marker: false, continuation: continuation)
        }
        out.append(NSAttributedString(string: "\n", attributes: lastAttributes))   // 表・面を、閉じる
        return out
    }

    /// 描くあいだ、共有するもの：同じ表の列の幅・同じ引用の面（段落をまたいで、1 本の線になる）。
    @MainActor final class Context {
        var tables: [Int: NSTextTable] = [:]
        var quotes: [Int: NSTextBlock] = [:]
        let tableWidths: [Int: [CGFloat]]
        init(tableWidths: [Int: [CGFloat]]) { self.tableWidths = tableWidths }
    }

    /// コピー用の文字（整形した見た目の文字だけ。記号は付かない）：箇条書きは `•`・番号、表は、タブ区切りの行。
    static func plainText(_ markdown: String) -> String {
        var out = ""
        var current: Int?
        var currentRow: Int?
        var lastItem: Int?
        for piece in pieces(markdown) {
            let continuation = piece.block.listDepth > 0 && piece.block.itemIdentity != nil && piece.block.itemIdentity == lastItem
            if piece.block.identity != current {
                if !out.isEmpty { out += piece.block.isTableCell && piece.block.row == currentRow ? "\t" : "\n" }
                current = piece.block.identity
                currentRow = piece.block.row
                if let prefix = piece.block.prefix, !continuation, !isTask(piece) { out += prefix }
                lastItem = piece.block.listDepth > 0 ? piece.block.itemIdentity : nil
            }
            out += cleaned(piece).replacingOccurrences(of: "\u{2028}", with: "\n")
        }
        return out
    }

    // MARK: 解析

    /// 同じ見た目の、1 まとまりの文字。
    struct Piece {
        var block: Block
        var text: String
        var inline: InlinePresentationIntent?
        var link: URL?
    }

    /// 文章の構造（ブロック）。
    struct Block: Equatable {
        enum Kind: Equatable { case plain, header(Int), paragraph, codeBlock, tableCell, rule }
        var kind: Kind = .plain
        var identity: Int?
        var listDepth = 0
        var ordinal: Int?
        /// いちばん内側の箇条書きが、番号つきか（番号つきの中の「•」の入れ子は、番号にしない）。
        var ordered = false
        /// いちばん内側の項目（同じ項目の、2 つ目以降の段落・コードには、行頭の記号を付けない）。
        var itemIdentity: Int?
        /// 引用の入れ子（外側から）。値は、引用ごとの番号（同じ引用の段落は、1 本の線でつなぐ）。
        var quotes: [Int] = []
        var row: Int?
        var column = 0
        var isHeaderRow = false
        var tableID: Int?
        var tableColumns = 1
        var alignments: [PresentationIntent.TableColumn.Alignment] = []

        /// 面（表・コードブロック）のまとまり：同じ表の中は、同じ値。面でなければ nil。
        var panelKey: Int? {
            if isTableCell { return tableID ?? identity }
            return kind == .codeBlock ? identity : nil
        }

        init(_ intent: PresentationIntent?) {
            guard let intent else { return }
            identity = intent.components.first?.identity
            var innermostListSeen = false
            // components は、内側から
            for component in intent.components {
                switch component.kind {
                case .header(let level): kind = .header(level)
                case .paragraph: kind = .paragraph
                case .codeBlock: kind = .codeBlock
                case .thematicBreak: kind = .rule
                case .tableCell(let column): kind = .tableCell; self.column = column
                case .table(let columns): tableID = component.identity; tableColumns = max(1, columns.count); alignments = columns.map(\.alignment)
                case .tableHeaderRow: isHeaderRow = true; row = 0
                case .tableRow(let index): row = index
                case .blockQuote: quotes.insert(component.identity, at: 0)
                case .unorderedList: listDepth += 1; if !innermostListSeen { ordered = false; innermostListSeen = true }
                case .orderedList: listDepth += 1; if !innermostListSeen { ordered = true; innermostListSeen = true }
                case .listItem(let n): if ordinal == nil { ordinal = n; itemIdentity = component.identity }
                default: break
                }
            }
        }

        var isTableCell: Bool { kind == .tableCell }
        var inQuote: Bool { !quotes.isEmpty }
        var isHeader: Bool { if case .header = kind { return true } else { return false } }
        /// 箇条書きの行頭（番号つきは、`1.`）。
        var prefix: String? {
            guard listDepth > 0, let ordinal else { return nil }
            return ordered ? "\(ordinal).\t" : "•\t"
        }
    }

    static func pieces(_ markdown: String) -> [Piece] {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: namingEmptyImages(resolvingFootnotes(markdown)), options: options) else { return [] }   // try?: 解析できなければ、空（呼び出し側が、元の文字を出す）
        var pieces: [Piece] = []
        var softBreaks: [Int] = []   // 前後に応じて、つなぎ方を決める改行（下）
        var htmlStyles: InlinePresentationIntent = []   // `<b>`…`</b>` などの、書式の HTML（段落の中だけ）
        var htmlBlock: Int?
        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            let block = Block(run.presentationIntent)
            var inline = run.inlinePresentationIntent
            var link = run.link
            if block.identity != htmlBlock { htmlBlock = block.identity; htmlStyles = [] }
            if block.kind != .codeBlock, inline?.contains(.code) != true, let tag = formattingTag(text) {
                // 書式の HTML の印は、見せずに、間の文字へ書式を付ける
                if tag.open { htmlStyles.insert(tag.style) } else { htmlStyles.remove(tag.style) }
                continue
            }
            if !htmlStyles.isEmpty, block.kind != .codeBlock { inline = (inline ?? []).union(htmlStyles) }
            if block.kind == .codeBlock {
                if text.hasSuffix("\n") { text.removeLast() }   // コードブロックの末尾の改行は、ブロックの区切りと重なる
            } else if block.kind == .plain {
                // HTML のブロック：中身は、そのまま見せる（行の間の空きを入れず、末尾の空行を落とす）
                text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: lineSeparator)
            } else if inline?.contains(.lineBreak) == true {
                text = lineSeparator   // 段落を分けない改行（段落の間の空きが、入らない）
            } else if inline?.contains(.softBreak) == true {
                softBreaks.append(pieces.count)
            } else if inline?.contains(.code) != true {
                text = replacingBreakTags(text)
            }
            if let image = run.imageURL {
                // 画像は出せない：代わりの文字（なければ「画像」）を、画像の印つきの、リンクにする
                text = "🖼 " + (text.isEmpty ? "画像" : text)
                link = image
            }
            pieces.append(Piece(block: block, text: text, inline: inline, link: link))
        }
        // ソフトブレーク：前か後が日本語などの全角の文字（約物を含む）なら、つなぐ（半角の空白を入れると、不自然に空く）。両方が半角なら、空白 1 つ
        for i in softBreaks {
            let before = i > 0 ? pieces[i - 1].text.last : nil
            let after = i + 1 < pieces.count ? pieces[i + 1].text.first : nil
            pieces[i].text = (before.map(isWide) ?? false) || (after.map(isWide) ?? false) ? "" : " "
        }
        return fillingEmptyCells(pieces)
    }

    /// 書式を付ける HTML の印（`<b>`・`</b>` など）か。`open`：開く印。
    private static func formattingTag(_ text: String) -> (open: Bool, style: InlinePresentationIntent)? {
        guard text.hasPrefix("<"), text.hasSuffix(">"), text.count <= 10 else { return nil }
        let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
        let open = !inner.hasPrefix("/")
        switch open ? inner : String(inner.dropFirst()) {
        case "b", "strong": return (open, .stronglyEmphasized)
        case "i", "em": return (open, .emphasized)
        case "code", "kbd": return (open, .code)
        case "s", "del", "strike": return (open, .strikethrough)
        default: return nil
        }
    }

    // MARK: 脚注

    private static let superscripts = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")

    /// 脚注（`[^名前]` と、`[^名前]: 本文`）を、上付きの番号と、末尾の一覧にする。Foundation は、脚注を扱わず、本文が消える（`[^名前]: …` は、リンクの定義として、読み捨てられる）。
    /// コードブロックの中・インラインコードの中は、触らない。定義のない参照は、そのまま。脚注がなければ、文章を変えない。
    static func resolvingFootnotes(_ markdown: String) -> String {
        guard markdown.contains("[^") else { return markdown }
        let lines = markdown.components(separatedBy: "\n")
        var fenced = false
        var body: [String] = []
        var definitions: [String: String] = [:]
        var order: [String] = []        // 定義の出てくる順
        var lastDefinition: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); body.append(line); lastDefinition = nil; continue }
            if fenced { body.append(line); continue }
            if let match = line.range(of: "^\\[\\^([^\\]\\s]+)\\]:\\s*", options: .regularExpression) {
                let id = String(line[match].dropFirst(2).prefix { $0 != "]" })
                definitions[id] = String(line[match.upperBound...])
                order.append(id)
                lastDefinition = id
                continue
            }
            // 定義の続き（字下げした行）
            if let id = lastDefinition, line.hasPrefix("    ") || line.hasPrefix("\t"), !trimmed.isEmpty {
                definitions[id, default: ""] += " " + trimmed
                continue
            }
            if !trimmed.isEmpty { lastDefinition = nil }
            body.append(line)
        }
        guard !definitions.isEmpty else { return markdown }
        // 参照を、出てくる順に、番号にする
        var numbers: [String: Int] = [:]
        var inFence = false
        let replaced = body.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); return line }
            if inFence || !line.contains("[^") { return line }
            // インラインコード（バッククォートの間）は、触らない：奇数番目の区間
            let parts = line.components(separatedBy: "`")
            return parts.enumerated().map { index, part -> String in
                guard index % 2 == 0, part.contains("[^") else { return part }
                var result = part
                let reference = try? NSRegularExpression(pattern: "\\[\\^([^\\]\\s]+)\\]")   // try?: 固定の式
                let whole = NSRange(part.startIndex..., in: part)
                let matches: [(id: String, range: Range<String.Index>)] = (reference?.matches(in: part, range: whole) ?? []).compactMap { match in
                    guard let idRange = Range(match.range(at: 1), in: part), let full = Range(match.range, in: part), definitions[String(part[idRange])] != nil else { return nil }
                    return (String(part[idRange]), full)
                }
                for match in matches where numbers[match.id] == nil { numbers[match.id] = numbers.count + 1 }   // 番号は、出てくる順
                for match in matches.reversed() { result.replaceSubrange(match.range, with: superscript(numbers[match.id]!)) }   // 置き換えは、後ろから（前の位置が、ずれない）
                return result
            }.joined(separator: "`")
        }
        // 参照された脚注（番号の順）、そのあと、参照されなかった定義
        var notes = numbers.sorted { $0.value < $1.value }.map { ($0.value, definitions[$0.key] ?? "") }
        var extra = notes.count
        for id in order where numbers[id] == nil { extra += 1; notes.append((extra, definitions[id] ?? "")) }
        let list = notes.map { "\(superscript($0.0)) \($0.1)" }.joined(separator: "  \n")
        return (replaced + ["", "---", "", list, ""]).joined(separator: "\n")
    }

    /// 代わりの文字のない画像（`![](…)`）に、「画像」と付ける（Foundation は、文字のない画像を、何も出さない）。コードの中は、触らない。
    static func namingEmptyImages(_ markdown: String) -> String {
        guard markdown.contains("![](") else { return markdown }
        var fenced = false
        return markdown.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); return line }
            if fenced || !line.contains("![](") { return line }
            return line.components(separatedBy: "`").enumerated().map { $0.offset % 2 == 0 ? $0.element.replacingOccurrences(of: "![](", with: "![画像](") : $0.element }.joined(separator: "`")
        }.joined(separator: "\n")
    }

    private static func superscript(_ n: Int) -> String { String(String(n).compactMap { $0.wholeNumberValue }.map { superscripts[$0] }) }

    /// 段落を分けない改行（`NSTextView` の、行の区切り）。
    static let lineSeparator = "\u{2028}"

    /// ASCII でない（日本語など。全角の約物を含む）の文字。
    private static func isWide(_ c: Character) -> Bool { !c.isASCII && !c.isWhitespace }

    /// `<br>`・`<br/>`・`<br />` は、改行にする（表のセルの中の改行に、よく使われる）。ほかの HTML は、そのまま見せる（隠さない）。
    private static func replacingBreakTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return text.replacingOccurrences(of: "<br\\s*/?>", with: lineSeparator, options: [.regularExpression, .caseInsensitive])
    }

    /// 空のセル（Foundation は、文字のないセルを、出さない）を、足す：行の中の、足りない列・行の終わりの列。足さないと、行が崩れる。
    private static func fillingEmptyCells(_ pieces: [Piece]) -> [Piece] {
        guard pieces.contains(where: { $0.block.isTableCell }) else { return pieces }
        var out: [Piece] = []
        var rowKey: String?
        var nextColumn = 0
        var template: Block?
        var synthetic = -1
        func close() {
            guard let template, template.tableColumns > nextColumn else { return }
            for column in nextColumn..<template.tableColumns { out.append(empty(template, column)) }
        }
        func empty(_ template: Block, _ column: Int) -> Piece {
            synthetic -= 1
            var block = template
            block.column = column
            block.identity = synthetic
            return Piece(block: block, text: "", inline: nil, link: nil)
        }
        for piece in pieces {
            let block = piece.block
            guard block.isTableCell, let table = block.tableID else {
                close(); rowKey = nil; template = nil; nextColumn = 0
                out.append(piece)
                continue
            }
            let key = "\(table)-\(block.row ?? 0)"
            if key != rowKey { close(); rowKey = key; nextColumn = 0 }
            template = block
            if block.column > nextColumn { for column in nextColumn..<block.column { out.append(empty(block, column)) } }
            out.append(piece)
            nextColumn = block.column + 1
        }
        close()
        return out
    }

    private static func isTask(_ piece: Piece) -> Bool {
        piece.block.listDepth > 0 && (piece.text.hasPrefix("[ ] ") || piece.text.hasPrefix("[x] ") || piece.text.hasPrefix("[X] "))
    }

    /// タスクリスト（`[ ]`・`[x]`）は、記号にする。区切り線は、空の 1 行（面で描く）。
    private static func cleaned(_ piece: Piece) -> String {
        if piece.block.kind == .rule { return "\u{200B}" }
        if piece.block.listDepth > 0 {
            if piece.text.hasPrefix("[ ] ") { return "☐ " + piece.text.dropFirst(4) }
            if piece.text.hasPrefix("[x] ") || piece.text.hasPrefix("[X] ") { return "☑ " + piece.text.dropFirst(4) }
        }
        return piece.text
    }

    // MARK: 表の列の幅

    /// 表の列の幅（割合。合計 100）：中身の長さに合わせる（等分だと、短い列が余り、長い列が、折り返す）。
    /// 全部が 1 行で収まるなら、1 行の幅の比。収まらなければ、各列の最小幅（長い語）を確保して、残りを、折り返してよい幅の比で分ける。
    @MainActor static func columnWidths(of pieces: [Piece]) -> [Int: [CGFloat]] {
        var natural: [Int: [Int: CGFloat]] = [:]    // 表 → 列 → 1 行の幅
        var minimum: [Int: [Int: CGFloat]] = [:]    // 表 → 列 → いちばん長い語の幅
        var count: [Int: Int] = [:]
        for piece in pieces where piece.block.isTableCell {
            guard let table = piece.block.tableID else { continue }
            count[table] = piece.block.tableColumns
            let font = NSFont.systemFont(ofSize: bodySize - 1, weight: piece.block.isHeaderRow ? .semibold : .regular)
            let text = cleaned(piece).replacingOccurrences(of: lineSeparator, with: "\n")
            var widest: CGFloat = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                widest = max(widest, ceil((String(line) as NSString).size(withAttributes: [.font: font]).width))
            }
            // 折り返せない最小の幅：半角の語（メール・日付・URL）は、語の全体。日本語を含む語は、どこでも折り返せるので、3 文字ぶんまで
            let word = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { token -> CGFloat in
                let width = ceil((String(token) as NSString).size(withAttributes: [.font: font]).width)
                return hasWideText(String(token)) ? min(width, 3 * (bodySize - 1) + 4) : min(width, 260)
            }.max() ?? 0
            let column = piece.block.column
            natural[table, default: [:]][column] = max(natural[table]?[column] ?? 0, min(widest, 520))
            // 日本語は、どこでも折り返せる：語の幅は、3 文字ぶんまで
            minimum[table, default: [:]][column] = max(minimum[table]?[column] ?? 0, min(word, widest))
        }
        let available: CGFloat = 600, padding: CGFloat = 15
        var result: [Int: [CGFloat]] = [:]
        for (table, columns) in count {
            let maxima = (0..<columns).map { (natural[table]?[$0] ?? 0) + padding }
            let minima = (0..<columns).map { min((minimum[table]?[$0] ?? 0) + padding, maxima[$0]) }
            var widths = maxima
            if maxima.reduce(0, +) > available {
                let base = minima.reduce(0, +)
                let spare = (0..<columns).map { maxima[$0] - minima[$0] }
                let room = max(0, available - base)
                let total = spare.reduce(0, +)
                widths = (0..<columns).map { total > 0 ? minima[$0] + room * spare[$0] / total : minima[$0] }
            }
            let sum = max(1, widths.reduce(0, +))
            result[table] = widths.map { $0 / sum * 100 }
        }
        return result
    }

    // MARK: 見た目（暗いガラスの上）

    private static let bodySize: CGFloat = 15
    private static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    private static let accent = NSColor.systemTeal

    /// 日本語などの文字を含むか（斜体の字形が、ない）。
    private static func hasWideText(_ text: String) -> Bool { text.contains { isWide($0) } }

    @MainActor private static func attributes(for block: Block, inline: InlinePresentationIntent?, link: URL?, text: String, context: Context, marker: Bool, continuation: Bool) -> [NSAttributedString.Key: Any] {
        var font: NSFont
        var color = HUDStyle.primary
        switch block.kind {
        case .header(let level):
            let size: CGFloat = [25, 20, 17, 15, 15, 15][min(max(level, 1), 6) - 1]
            font = .systemFont(ofSize: size, weight: level == 1 ? .bold : .semibold)
            color = level >= 4 ? HUDStyle.secondary : .white
        case .codeBlock:
            font = .monospacedSystemFont(ofSize: bodySize - 2, weight: .regular)
        case .plain:
            // HTML のブロック：そのまま（記号の文字）。控えめな色の、等幅
            font = .monospacedSystemFont(ofSize: bodySize - 2, weight: .regular)
            color = HUDStyle.secondary
        case .rule:
            font = .systemFont(ofSize: 2)   // 線だけの行：文字の高さを、小さくする
        case .tableCell:
            font = .systemFont(ofSize: bodySize - 1, weight: block.isHeaderRow ? .semibold : .regular)
        default:
            font = bodyFont
        }
        if block.inQuote { color = HUDStyle.secondary }
        var attrs: [NSAttributedString.Key: Any] = [:]
        if let inline {
            if inline.contains(.code) {
                font = .monospacedSystemFont(ofSize: font.pointSize - 1.5, weight: .regular)
                attrs[.backgroundColor] = HUDStyle.hairline(0.14)
                color = NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.5, alpha: 1)
            }
            if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask); color = .white }
            if inline.contains(.emphasized) {
                // 日本語には、斜体の字形がない：文字を、斜めにする（半角の英数字は、本物の斜体）
                if hasWideText(text) { attrs[.obliqueness] = 0.2 } else { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            }
            if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; color = HUDStyle.secondary }
        }
        if let link { attrs[.link] = link; attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue; color = accent }
        if marker { color = accent }   // 箇条書きの「•」・番号
        attrs[.font] = font
        attrs[.foregroundColor] = color
        attrs[.paragraphStyle] = paragraphStyle(for: block, context: context, continuation: continuation)
        return attrs
    }

    @MainActor private static func paragraphStyle(for block: Block, context: Context, continuation: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 10
        var blocks: [NSTextBlock] = block.quotes.map { quoteBlock($0, context: context) }
        let indent = CGFloat(block.listDepth) * 24
        switch block.kind {
        case .header(let level):
            style.paragraphSpacingBefore = level == 1 ? 4 : level <= 3 ? 12 : 6
            style.paragraphSpacing = level <= 3 ? 8 : 4
        case .codeBlock:
            style.lineSpacing = 3
            style.paragraphSpacing = 0   // コードの行の間は、空けない
            // 箇条書きの中のコードは、項目の字下げに合わせる（見えない面で、左を空ける）
            if block.listDepth > 0 { blocks.append(indentBlock(indent)) }
            blocks.append(panel(background: HUDStyle.hairline(0.09), padding: 10))
        case .rule:
            style.lineSpacing = 0
            style.paragraphSpacing = 4
            style.paragraphSpacingBefore = 4
            blocks.append(rule())
        case .tableCell:
            if let id = block.tableID {
                let table = context.tables[id] ?? { let t = NSTextTable(); t.numberOfColumns = block.tableColumns; t.collapsesBorders = true
                    t.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY); t.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)   // 前後の段落との間
                    context.tables[id] = t; return t }()
                let cell = NSTextTableBlock(table: table, startingRow: block.row ?? 0, rowSpan: 1, startingColumn: block.column, columnSpan: 1)
                cell.setBorderColor(HUDStyle.hairline(0.2))
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setWidth(7, type: .absoluteValueType, for: .padding)
                if let widths = context.tableWidths[id], block.column < widths.count { cell.setContentWidth(widths[block.column], type: .percentageValueType) }
                if block.isHeaderRow { cell.backgroundColor = HUDStyle.hairline(0.12) }
                blocks.append(cell)
            }
            switch block.column < block.alignments.count ? block.alignments[block.column] : .left {
            case .center: style.alignment = .center
            case .right: style.alignment = .right
            default: style.alignment = .left
            }
            style.paragraphSpacing = 0
            style.lineSpacing = 2
        default: break
        }
        style.textBlocks = blocks
        if block.listDepth > 0, block.kind != .codeBlock {
            // 記号のある行：記号を、字下げの手前に。記号のない行（項目の 2 つ目以降）：本文の位置に揃える
            style.firstLineHeadIndent = continuation || block.prefix == nil ? indent : indent - 18
            style.headIndent = indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.paragraphSpacing = 5
        }
        return style
    }

    /// 引用の面（左の線）。同じ引用の段落は、同じ面にして、1 本の線でつなぐ。
    @MainActor private static func quoteBlock(_ id: Int, context: Context) -> NSTextBlock {
        if let existing = context.quotes[id] { return existing }
        let bar = NSTextBlock()
        bar.setContentWidth(100, type: .percentageValueType)   // 幅を決めないと、1 文字の幅になる
        bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        bar.setBorderColor(accent.withAlphaComponent(0.75), for: .minX)
        bar.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        bar.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
        bar.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)
        context.quotes[id] = bar
        return bar
    }

    /// 面の後ろの、小さな空き（高さ 8 ほどの、空の段落）。
    @MainActor private static func spacer() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        return NSAttributedString(string: "\u{200B}\n", attributes: [.font: NSFont.systemFont(ofSize: 5), .paragraphStyle: style])
    }

    /// 左を空けるだけの、見えない面（箇条書きの中の、コード）。
    @MainActor private static func indentBlock(_ indent: CGFloat) -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(indent, type: .absoluteValueType, for: .padding, edge: .minX)
        return block
    }

    /// 面（コードブロック）。
    @MainActor private static func panel(background: NSColor, padding: CGFloat) -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)   // 前後の段落との間
        block.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)
        block.backgroundColor = background
        block.setWidth(padding, type: .absoluteValueType, for: .padding)
        block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .maxY)
        return block
    }

    /// 区切り線：上の縁だけの、細い面。
    @MainActor private static func rule() -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(HUDStyle.hairline(0.22), for: .minY)
        return block
    }
}

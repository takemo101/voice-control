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
        var tables: [Int: NSTextTable] = [:]
        var lastPanel: Int?
        for piece in pieces {
            if piece.block.identity != current {
                // 段落の区切り（直前の段落の見た目を引き継ぐ：表のセルや、引用の面が、途切れない）
                if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: lastAttributes)) }
                // 表・コードブロックの面の後ろには、小さな空きを入れる（面は、次の段落に、くっついて見える）
                if let lastPanel, lastPanel != piece.block.panelKey { out.append(Self.spacer()) }
                lastPanel = piece.block.panelKey
                current = piece.block.identity
                // タスクリストは、箇条書きの「•」ではなく、☐・☑ だけ
                if let prefix = piece.block.prefix, !Self.isTask(piece) {
                    out.append(NSAttributedString(string: prefix, attributes: Self.attributes(for: piece.block, inline: nil, link: nil, tables: &tables, marker: true)))
                }
            }
            let text = Self.cleaned(piece)
            let attrs = Self.attributes(for: piece.block, inline: piece.inline, link: piece.link, tables: &tables, marker: false)
            out.append(NSAttributedString(string: text, attributes: attrs))
            lastAttributes = Self.attributes(for: piece.block, inline: nil, link: nil, tables: &tables, marker: false)
        }
        out.append(NSAttributedString(string: "\n", attributes: lastAttributes))   // 表・面を、閉じる
        return out
    }

    /// コピー用の文字（整形した見た目の文字だけ。記号は付かない）：箇条書きは `•`・番号、表は、タブ区切りの行。
    static func plainText(_ markdown: String) -> String {
        var out = ""
        var current: Int?
        var currentRow: Int?
        for piece in pieces(markdown) {
            if piece.block.identity != current {
                if !out.isEmpty { out += piece.block.isTableCell && piece.block.row == currentRow ? "\t" : "\n" }
                current = piece.block.identity
                currentRow = piece.block.row
                if let prefix = piece.block.prefix, !isTask(piece) { out += prefix }
            }
            out += cleaned(piece)
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
        var ordered = false
        var inQuote = false
        var row: Int?
        var column = 0
        var isHeaderRow = false
        var tableID: Int?
        var tableColumns = 1

        /// 面（表・コードブロック）のまとまり：同じ表の中は、同じ値。面でなければ nil。
        var panelKey: Int? {
            if isTableCell { return tableID ?? identity }
            return kind == .codeBlock ? identity : nil
        }

        init(_ intent: PresentationIntent?) {
            guard let intent else { return }
            identity = intent.components.first?.identity
            for component in intent.components {
                switch component.kind {
                case .header(let level): kind = .header(level)
                case .paragraph: kind = .paragraph
                case .codeBlock: kind = .codeBlock
                case .thematicBreak: kind = .rule
                case .tableCell(let column): kind = .tableCell; self.column = column
                case .table(let columns): tableID = component.identity; tableColumns = max(1, columns.count)
                case .tableHeaderRow: isHeaderRow = true; row = 0
                case .tableRow(let index): row = index
                case .blockQuote: inQuote = true
                case .unorderedList: listDepth += 1
                case .orderedList: listDepth += 1; ordered = true
                case .listItem(let n): if ordinal == nil { ordinal = n }
                default: break
                }
            }
        }

        var isTableCell: Bool { kind == .tableCell }
        var isHeader: Bool { if case .header = kind { return true } else { return false } }
        /// 箇条書きの行頭（番号つきは、`1.`）。
        var prefix: String? {
            guard listDepth > 0, let ordinal else { return nil }
            return ordered ? "\(ordinal).\t" : "•\t"
        }
    }

    static func pieces(_ markdown: String) -> [Piece] {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return [] }   // try?: 解析できなければ、空（呼び出し側が、元の文字を出す）
        return parsed.runs.map { run in
            var text = String(parsed[run.range].characters)
            let block = Block(run.presentationIntent)
            if block.kind == .codeBlock, text.hasSuffix("\n") { text.removeLast() }   // コードブロックの末尾の改行は、ブロックの区切りと重なる
            return Piece(block: block, text: text, inline: run.inlinePresentationIntent, link: run.link)
        }
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

    // MARK: 見た目（暗いガラスの上）

    private static let bodySize: CGFloat = 15
    private static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    private static let accent = NSColor.systemTeal

    @MainActor private static func attributes(for block: Block, inline: InlinePresentationIntent?, link: URL?, tables: inout [Int: NSTextTable], marker: Bool) -> [NSAttributedString.Key: Any] {
        var font: NSFont
        var color = HUDStyle.primary
        switch block.kind {
        case .header(let level):
            let size: CGFloat = [25, 20, 17, 15, 15, 15][min(max(level, 1), 6) - 1]
            font = .systemFont(ofSize: size, weight: level == 1 ? .bold : .semibold)
            color = level >= 4 ? HUDStyle.secondary : .white
        case .codeBlock:
            font = .monospacedSystemFont(ofSize: bodySize - 2, weight: .regular)
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
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; color = HUDStyle.secondary }
        }
        if let link { attrs[.link] = link; attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue; color = accent }
        if marker { color = accent }   // 箇条書きの「•」・番号
        attrs[.font] = font
        attrs[.foregroundColor] = color
        attrs[.paragraphStyle] = paragraphStyle(for: block, tables: &tables)
        return attrs
    }

    @MainActor private static func paragraphStyle(for block: Block, tables: inout [Int: NSTextTable]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 10
        switch block.kind {
        case .header(let level):
            style.paragraphSpacingBefore = level == 1 ? 4 : 12
            style.paragraphSpacing = 8
        case .codeBlock:
            style.lineSpacing = 3
            style.paragraphSpacing = 0   // コードの行の間は、空けない
            style.textBlocks = [panel(background: HUDStyle.hairline(0.09), padding: 10)]
        case .rule:
            style.lineSpacing = 0
            style.paragraphSpacing = 4
            style.paragraphSpacingBefore = 4
            style.textBlocks = [rule()]
        case .tableCell:
            if let id = block.tableID {
                let table = tables[id] ?? { let t = NSTextTable(); t.numberOfColumns = block.tableColumns; t.collapsesBorders = true
                    t.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY); t.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)   // 前後の段落との間
                    tables[id] = t; return t }()
                let cell = NSTextTableBlock(table: table, startingRow: block.row ?? 0, rowSpan: 1, startingColumn: block.column, columnSpan: 1)
                cell.setBorderColor(HUDStyle.hairline(0.2))
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setWidth(7, type: .absoluteValueType, for: .padding)
                if block.isHeaderRow { cell.backgroundColor = HUDStyle.hairline(0.12) }
                style.textBlocks = [cell]
            }
            style.paragraphSpacing = 0
            style.lineSpacing = 2
        default: break
        }
        if block.inQuote, block.kind != .codeBlock {
            let bar = NSTextBlock()
            bar.setContentWidth(100, type: .percentageValueType)   // 幅を決めないと、1 文字の幅になる
            bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            bar.setBorderColor(accent.withAlphaComponent(0.75), for: .minX)
            bar.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            bar.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
            bar.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
            style.textBlocks = [bar]
        }
        if block.listDepth > 0 {
            let indent = CGFloat(block.listDepth) * 24
            style.firstLineHeadIndent = indent - 18
            style.headIndent = indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.paragraphSpacing = 5
        }
        return style
    }

    /// 面の後ろの、小さな空き（高さ 8 ほどの、空の段落）。
    @MainActor private static func spacer() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        return NSAttributedString(string: "\u{200B}\n", attributes: [.font: NSFont.systemFont(ofSize: 5), .paragraphStyle: style])
    }

    /// 面（コードブロック）。
    @MainActor private static func panel(background: NSColor, padding: CGFloat) -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)   // 前後の段落との間
        block.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)
        block.backgroundColor = background
        block.setWidth(padding, type: .absoluteValueType, for: .padding)
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

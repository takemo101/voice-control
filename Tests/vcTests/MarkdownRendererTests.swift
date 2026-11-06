import AppKit
import Testing
@testable import vc

/// Markdown の整形（`vc show` のウィンドウ）：見出し・太字・リンク・箇条書き・コード・表が、見た目の違いになる。
@MainActor @Suite struct MarkdownRendererTests {
    private let sample = """
    # 返信案

    **はい**、14時で大丈夫です。`code` と [リンク](https://example.com)

    - 項目 1
    - 項目 2

    1. 手順 A
    2. 手順 B

    > 引用

    ```
    let x = 1
    ```

    | 列1 | 列2 |
    |---|---|
    | a | b |
    """

    private func attributes(of needle: String, in text: NSAttributedString) -> [NSAttributedString.Key: Any]? {
        let range = (text.string as NSString).range(of: needle)
        return range.location == NSNotFound ? nil : text.attributes(at: range.location, effectiveRange: nil)
    }
    private func font(_ needle: String, _ text: NSAttributedString) -> NSFont? { attributes(of: needle, in: text)?[.font] as? NSFont }

    @Test func headingsAreLargerAndBoldAndBodyTextIsNormal() throws {
        let text = MarkdownRenderer.render(sample)
        let heading = try #require(font("返信案", text)), body = try #require(font("大丈夫", text))
        #expect(heading.pointSize > body.pointSize)
        #expect(NSFontManager.shared.traits(of: heading).contains(.boldFontMask))
        #expect(!NSFontManager.shared.traits(of: body).contains(.boldFontMask))
    }

    @Test func boldCodeAndLinksCarryTheirOwnLook() throws {
        let text = MarkdownRenderer.render(sample)
        #expect(NSFontManager.shared.traits(of: try #require(font("はい", text))).contains(.boldFontMask))
        #expect(try #require(font("code", text)).isFixedPitch)
        #expect(attributes(of: "リンク", in: text)?[.link] as? URL == URL(string: "https://example.com"))
    }

    @Test func listsGetBulletsAndNumbersAndTheMarkdownSymbolsDisappear() {
        let plain = MarkdownRenderer.plainText(sample)
        #expect(plain.contains("•\t項目 1") && plain.contains("•\t項目 2"))
        #expect(plain.contains("1.\t手順 A") && plain.contains("2.\t手順 B"))
        #expect(!plain.contains("**") && !plain.contains("# ") && !plain.contains("```") && !plain.contains("](") )
    }

    @Test func codeBlocksAreMonospacedPanelsAndTablesAreBorderedCells() throws {
        let text = MarkdownRenderer.render(sample)
        #expect(try #require(font("let x = 1", text)).isFixedPitch)
        func blocks(_ needle: String) -> [NSTextBlock] { (attributes(of: needle, in: text)?[.paragraphStyle] as? NSParagraphStyle)?.textBlocks ?? [] }
        #expect(blocks("let x = 1").first?.backgroundColor != nil)        // コードブロックは、面
        #expect(blocks("列1").first is NSTextTableBlock && blocks("b").first is NSTextTableBlock)   // 表は、セル
        // コピー用の文字では、表は、タブ区切りの行
        #expect(MarkdownRenderer.plainText(sample).contains("列1\t列2\na\tb"))
    }

    @Test func quotesGetABarRulesGetALineAndTasksGetBoxes() throws {
        let text = MarkdownRenderer.render("> 引用\n\n---\n\n- [ ] 未\n- [x] 済")
        let quote = (attributes(of: "引用", in: text)?[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first
        #expect(quote != nil && quote?.width(for: .border, edge: .minX) == 3)      // 左の線
        #expect(text.string.contains("☐ 未") && text.string.contains("☑ 済"))
        #expect(!text.string.contains("[ ]") && !text.string.contains("[x]"))
        #expect(MarkdownRenderer.plainText("上\n\n---\n\n下").contains("上") )
    }

    // MARK: 一通りの記法を描いて見つけた不具合（番号つきの中の「•」・項目の続きの段落・改行・空のセル・脚注 など）

    /// 番号つきの項目の中の、箇条書き（入れ子）は、番号ではなく「•」。
    @Test func aBulletNestedInANumberedListKeepsItsBullet() {
        let plain = MarkdownRenderer.plainText("1. 準備\n   - 道具\n   - 場所\n2. 実行")
        #expect(plain == "1.\t準備\n•\t道具\n•\t場所\n2.\t実行")
    }

    /// 項目の 2 つ目の段落・コードには、行頭の記号を付けない（付けると、項目が増えたように見える）。
    @Test func laterBlocksOfOneItemGetNoMarker() {
        #expect(MarkdownRenderer.plainText("- a\n\n  b\n- c") == "•\ta\nb\n•\tc")
        #expect(MarkdownRenderer.plainText("- a\n\n  ```\n  code\n  ```\n- c") == "•\ta\ncode\n•\tc")
    }

    /// 行末の空白 2 つ・バックスラッシュの改行は、段落を分けない改行（段落の間の空きが入らない）。コピーでは、ふつうの改行。
    @Test func aHardBreakStaysInsideTheParagraph() {
        let text = MarkdownRenderer.render("上  \n下")
        #expect(text.string == "上\u{2028}下\n")
        #expect(MarkdownRenderer.plainText("上  \n下") == "上\n下")
        #expect(MarkdownRenderer.plainText("上\\\n下") == "上\n下")
    }

    /// 日本語の文の途中の改行は、空白にしない（半角の空白が空く）。英語どうしは、空白 1 つ。
    @Test func aSoftBreakJoinsJapaneseWithoutASpaceAndEnglishWithOne() {
        #expect(MarkdownRenderer.plainText("日本語の\n文です") == "日本語の文です")
        #expect(MarkdownRenderer.plainText("終わり。\n2 行目") == "終わり。2 行目")
        #expect(MarkdownRenderer.plainText("hello\nworld") == "hello world")
    }

    /// 空のセルも、列を保つ（Foundation は、文字のないセルを出さない）。行の途中・行の終わり。
    @Test func emptyTableCellsKeepTheColumns() {
        #expect(MarkdownRenderer.plainText("| a | b | c |\n|---|---|---|\n| 1 |  | 3 |\n| x | y |  |") == "a\tb\tc\n1\t\t3\nx\ty\t")
    }

    /// 表：列の揃え（左・中央・右）が効く。列の幅は、中身の長さに合わせる（等分にしない）。
    @Test func tablesHonourAlignmentAndSizeColumnsByContent() throws {
        let text = MarkdownRenderer.render("| 左 | 中 | 右 |\n|:--|:-:|--:|\n| 短い | 短い | 短い |\n| a | b | c |")
        func alignment(_ needle: String, last: Bool = false) -> NSTextAlignment? {
            let range = last ? (text.string as NSString).range(of: needle, options: .backwards) : (text.string as NSString).range(of: needle)
            return (text.attributes(at: range.location, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle)?.alignment
        }
        #expect(alignment("c", last: true) == .right && alignment("b", last: true) == .center && alignment("a", last: true) == .left)
        // 幅：1 列目が短く、2 列目が長い表なら、2 列目のほうが広い
        let wide = MarkdownRenderer.render("| id | 説明 |\n|---|---|\n| 1 | これはとても長い説明の文章で、1 行に収まる長さです。 |")
        func width(_ needle: String) throws -> CGFloat {
            let range = (wide.string as NSString).range(of: needle)
            let block = try #require((wide.attributes(at: range.location, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first)
            return block.contentWidth
        }
        #expect(try width("説明") > width("id") && (try width("id") + width("説明")).rounded() == 100)
    }

    /// 画像は出せない：代わりの文字（なければ「画像」）を、リンクで見せる。消えない。
    @Test func anImageShowsItsAltTextAsALink() {
        let text = MarkdownRenderer.render("![設計図](https://example.com/a.png)")
        #expect(text.string.contains("設計図"))
        #expect(attributes(of: "設計図", in: text)?[.link] as? URL == URL(string: "https://example.com/a.png"))
        #expect(MarkdownRenderer.render("![](https://example.com/a.png)").string.contains("画像"))
    }

    /// 斜体：日本語には字形がないので、斜めにする。半角の英数字は、本物の斜体。
    @Test func italicJapaneseIsSlantedAndLatinUsesAnItalicFont() throws {
        let text = MarkdownRenderer.render("*斜体* と *italic*")
        #expect((attributes(of: "斜体", in: text)?[.obliqueness] as? Double ?? 0) > 0)
        #expect(NSFontManager.shared.traits(of: try #require(font("italic", text))).contains(.italicFontMask))
    }

    /// 書式の HTML（`<b>`・`<i>`・`<br>`）は、印を見せずに、書式にする。ほかの HTML は、隠さない。
    @Test func formattingHtmlTagsBecomeStyleAndOtherTagsStayVisible() throws {
        let text = MarkdownRenderer.render("a <b>太</b> b<br>c <span>d</span> `<b>`")
        #expect(text.string.hasPrefix("a 太 b\u{2028}c <span>d</span> <b>"))
        #expect(NSFontManager.shared.traits(of: try #require(font("太", text))).contains(.boldFontMask))
    }

    /// 脚注：参照は上付きの番号に、本文は、末尾の一覧に（Foundation は、本文を捨てる）。コードの中は、触らない。
    @Test func footnotesBecomeNumbersWithAListAtTheEnd() {
        let plain = MarkdownRenderer.plainText("一つ目[^b]と二つ目[^a]。\n\n[^a]: あの注\n[^b]: びの注")
        #expect(plain.hasPrefix("一つ目¹と二つ目²。"))
        #expect(plain.contains("¹ びの注") && plain.contains("² あの注"))
        #expect(MarkdownRenderer.plainText("```\n[^a]: x\n```").contains("[^a]: x"))
        #expect(MarkdownRenderer.plainText("定義なし[^z]") == "定義なし[^z]")
    }

    /// 同じ引用の段落は、1 本の線（同じ面）でつなぐ。別の引用は、別の面。
    @Test func paragraphsOfOneQuoteShareOneBar() throws {
        let text = MarkdownRenderer.render("> 一\n>\n> 二\n\n> 別")
        func bar(_ needle: String) throws -> NSTextBlock { try #require((attributes(of: needle, in: text)?[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first) }
        #expect(try bar("一") === bar("二") && bar("一") !== bar("別"))
    }

    @Test func emptyAndPlainTextAreHandled() {
        #expect(MarkdownRenderer.render("").length == 0)
        #expect(MarkdownRenderer.plainText("ただの文") == "ただの文")
    }
}

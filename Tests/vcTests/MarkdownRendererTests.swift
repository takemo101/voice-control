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

    @Test func emptyAndPlainTextAreHandled() {
        #expect(MarkdownRenderer.render("").length == 0)
        #expect(MarkdownRenderer.plainText("ただの文") == "ただの文")
    }
}

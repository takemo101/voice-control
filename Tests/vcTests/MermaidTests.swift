import AppKit
import Foundation
import Testing
@testable import vc

/// Mermaid の図：描ける種類は、画像になる（上下が正しい・幅の上限）・描けないものは、nil（コードのまま）・円グラフ（自前）・Markdown の中で、画像になる。
@MainActor @Suite struct MermaidTests {
    private func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 上半分・下半分の、描かれた（透明でない）画素の数。
    private func ink(_ image: NSImage) -> (top: Int, bottom: Int)? {
        guard let cg = cgImage(image) else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var top = 0, bottom = 0
        for y in 0..<height { for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 32 { if y < height / 2 { top += 1 } else { bottom += 1 } } }
        return (top: top, bottom: bottom)   // 行 0 が、画像の上
    }

    @Test func supportedDiagramKindsBecomeImages() {
        let sources = [
            "graph TD\n A[開始] --> B{条件?}\n B -->|はい| C[処理]\n B -->|いいえ| D(処理 2)\n C --> E([終了])\n D --> E",
            "stateDiagram-v2\n [*] --> 待機\n 待機 --> 処理中: 開始\n 処理中 --> [*]",
            "sequenceDiagram\n participant U as ユーザー\n U->>S: 要求\n S-->>U: 応答\n Note over U,S: 完了",
            "classDiagram\n Animal <|-- Dog\n Animal : +String name\n Dog : +bark()",
            "erDiagram\n USER ||--o{ ORDER : places",
            "pie title 割合\n \"A\" : 60\n \"B\" : 40",
        ]
        for source in sources { #expect(MermaidImage.image(for: source) != nil, "描けるはず：\(source.prefix(30))") }
    }

    @Test func theImageIsTheRightWayUp() throws {
        // 上に、横に広い四角・下に、小さな丸：上半分のほうが、描かれた画素が多いはず（上下が逆なら、反対になる）
        let image = try #require(MermaidImage.image(for: "graph TD\n A[とても長い文字列を入れて、横に広い四角にするための、見本の文章です] --> B((x))"))
        let counts = try #require(ink(image))
        #expect(counts.top > counts.bottom, "上 \(counts.top)・下 \(counts.bottom)")
    }

    @Test func unsupportedBrokenOrHugeDiagramsAreNotDrawn() {
        for source in ["gantt\n title x\n section A\n t1 :a1, 2024-01-01, 3d", "journey\n title x", "mindmap\n root", "これは Mermaid ではない", "", "pie\n \"A\" : x", "pie\n"] {
            #expect(MermaidImage.image(for: source) == nil, "描かない：\(source.prefix(20))")
        }
        #expect(MermaidImage.image(for: String(repeating: "a", count: MermaidImage.maxSource + 1)) == nil)
        let tall = "graph TD\n" + (0..<150).map { "N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        #expect(MermaidImage.image(for: tall) == nil)                                            // 縦に長すぎて、縮めると読めない
    }

    @Test func aWideDiagramIsShrunkToTheWidthLimit() {
        let wide = (1...7).map { "N\($0)[ノード \($0)]" }.joined(separator: " --> ")
        let image = MermaidImage.image(for: "graph LR\n \(wide)")
        #expect(image != nil && image!.size.width <= MermaidImage.maxWidth)
        let tooWide = (1...20).map { "N\($0)[とても長いラベルのノード \($0)]" }.joined(separator: " --> ")
        #expect(MermaidImage.image(for: "graph LR\n \(tooWide)") == nil)                       // 縮めると読めない図は、コードのまま
    }

    @Test func pieChartsAreParsed() throws {
        let chart = try #require(PieChart.parse("pie showData title 割合\n \"A\" : 60\n \"B\" : 40"))
        #expect(chart.title == "割合" && chart.slices.map(\.value) == [60, 40] && chart.slices.map(\.label) == ["A", "B"])
        #expect(PieChart.parse("pie\n \"A\" : -1") == nil && PieChart.parse("pie\n \"A\" : 0") == nil)
    }

    @Test func aMermaidBlockInMarkdownBecomesAnImageAttachmentButTheCopiedTextKeepsTheSource() {
        let markdown = "前\n\n```mermaid\ngraph TD\n A --> B\n```\n\n後"
        let rendered = MarkdownRenderer.render(markdown)
        var attachments = 0
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in if value != nil { attachments += 1 } }
        #expect(attachments == 1)
        #expect(!rendered.string.contains("graph TD"))                                            // コードは、画像に置き換わる
        #expect(MarkdownRenderer.plainText(markdown).contains("graph TD"))                       // コピーするのは、元の文字
        #expect(MarkdownRenderer.render("```mermaid\ngantt\n title x\n```").string.contains("gantt"))   // 描けない図は、コードのまま
    }
}

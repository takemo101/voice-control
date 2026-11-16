import AppKit
import Foundation
import Testing
@testable import vc

/// Mermaid の図：解析（対応する種類・対応しないものは nil）・配置（重ならない・向き・循環・複数の線）・画像にできること。
@Suite struct MermaidTests {
    private func flow(_ source: String) -> FlowGraph? {
        if case .flow(let graph)? = MermaidDiagram.parse(source) { return graph }
        return nil
    }
    private let measure: (String) -> CGSize = { text in CGSize(width: CGFloat(text.count) * 8, height: CGFloat(text.components(separatedBy: "\n").count) * 16) }

    @Test func flowchartNodesShapesLabelsAndChainsAreParsed() throws {
        let graph = try #require(flow("""
        graph LR
            A[開始] --> B{条件?}
            B -->|はい| C([終了])
            B -- いいえ --> D((円))
            C & D --> E
            E -.-> A
            A ==> E
            F --x G
        """))
        #expect(graph.direction == .leftRight)
        func shape(_ id: String) -> FlowGraph.Shape? { graph.nodes.first { $0.id == id }?.shape }
        #expect(shape("A") == .rect && shape("B") == .diamond && shape("C") == .stadium && shape("D") == .circle)
        #expect(graph.nodes.first { $0.id == "B" }?.label == "条件?")
        func edge(_ from: String, _ to: String) -> FlowGraph.Edge? { graph.edges.first { $0.from == from && $0.to == to } }
        #expect(edge("B", "C")?.label == "はい" && edge("B", "D")?.label == "いいえ")
        #expect(edge("C", "E") != nil && edge("D", "E") != nil)                         // A & B --> C
        #expect(edge("E", "A")?.line == .dotted && edge("A", "E")?.line == .thick)
        #expect(edge("F", "G")?.head == .cross)
    }

    @Test func stateAndSequenceAndPieAreParsedAndUnknownKindsAreNotDrawn() throws {
        let state = try #require(flow("stateDiagram-v2\n [*] --> 待機\n 待機 --> 処理中: 開始\n 処理中 --> [*]"))
        #expect(state.nodes.contains { $0.shape == .startDot } && state.nodes.contains { $0.shape == .endDot } && state.edges.count == 3)
        guard case .sequence(let sequence)? = MermaidDiagram.parse("sequenceDiagram\n participant U as ユーザー\n U->>S: 要求\n S-->>U: 応答\n loop 毎分\n U->>S: ping\n end\n Note over U,S: 完了") else { Issue.record("シーケンス図"); return }
        #expect(sequence.participants.map(\.label) == ["ユーザー", "S"] && sequence.items.count == 6)
        guard case .pie(let pie)? = MermaidDiagram.parse("pie title 割合\n \"A\" : 60\n \"B\" : 40") else { Issue.record("円グラフ"); return }
        #expect(pie.title == "割合" && pie.slices.map(\.value) == [60, 40])
        for unsupported in ["gantt\n title x", "classDiagram\n A <|-- B", "erDiagram\n A ||--o{ B : has", "journey\n title x", "mindmap\n root", "", "graph TD\n", "stateDiagram-v2\n state X {\n A --> B\n }", "sequenceDiagram\n loop x\n A->>B: y", "pie\n \"A\" : x"] {
            #expect(MermaidDiagram.parse(unsupported) == nil, "描かない：\(unsupported)")
        }
    }

    @Test func nodesNeverOverlapAndFlowFollowsTheDirection() throws {
        let source = "graph TD\n A --> B\n A --> C\n B --> D\n C --> D\n D --> E\n A --> E"
        let graph = try #require(flow(source))
        let layout = FlowLayout.make(graph, measure: measure)
        for (i, a) in layout.nodes.enumerated() { for b in layout.nodes[(i + 1)...] { #expect(!a.frame.intersects(b.frame), "\(a.node.id) と \(b.node.id) が重なる") } }
        func y(_ id: String) -> CGFloat { layout.nodes.first { $0.node.id == id }!.frame.midY }
        #expect(y("A") < y("B") && y("B") < y("D") && y("D") < y("E"))                          // 上から下
        let horizontal = FlowLayout.make(try #require(flow(source.replacingOccurrences(of: "TD", with: "LR"))), measure: measure)
        func x(_ id: String) -> CGFloat { horizontal.nodes.first { $0.node.id == id }!.frame.midX }
        #expect(x("A") < x("B") && x("B") < x("D"))                                              // 左から右
        // 長い線（A → E）は、途中の点を通る
        #expect((layout.edges.first { $0.edge.from == "A" && $0.edge.to == "E" }?.points.count ?? 0) > 2)
    }

    @Test func cyclesAndSelfLoopsAndOpposingEdgesAreLaidOutWithoutOverlap() throws {
        let graph = try #require(flow("graph TD\n A --> B\n B --> A\n B --> B\n B --> C\n C --> A"))
        let layout = FlowLayout.make(graph, measure: measure)
        #expect(layout.nodes.count == 3 && layout.edges.count == 5)
        func y(_ id: String) -> CGFloat { layout.nodes.first { $0.node.id == id }!.frame.midY }
        #expect(y("A") < y("B") && y("B") < y("C"))
        // A→B と B→A は、同じ直線にならない（ずらす）
        let forward = layout.edges.first { $0.edge.from == "A" && $0.edge.to == "B" }!, back = layout.edges.first { $0.edge.from == "B" && $0.edge.to == "A" }!
        #expect(abs(forward.points[0].x - back.points[0].x) > 8)
        // すべての点が、図の中に入っている
        for e in layout.edges { for p in e.points { #expect(p.x >= 0 && p.y >= 0 && p.x <= layout.size.width && p.y <= layout.size.height) } }
    }

    @Test func sequenceColumnsAreOrderedAndMessagesDescend() throws {
        guard case .sequence(let sequence)? = MermaidDiagram.parse("sequenceDiagram\n A->>B: とても長いメッセージの文字列で、間隔を広げる\n B-->>A: 応答\n A->>A: 自分へ") else { Issue.record("シーケンス図"); return }
        let layout = SequenceLayout.make(sequence, measure: measure)
        #expect(layout.lifelineX[0] < layout.lifelineX[1])
        #expect(layout.lifelineX[1] - layout.lifelineX[0] >= measure("とても長いメッセージの文字列で、間隔を広げる").width)
        #expect(layout.messages.count == 3 && layout.messages[0].y < layout.messages[1].y && layout.messages[1].y < layout.messages[2].y)
        #expect(layout.messages[2].isSelf && layout.size.height > layout.messages[2].y)
    }

    @MainActor @Test func drawableDiagramsBecomeImagesNoWiderThanTheLimitAndBadOnesDoNot() {
        let wide = (1...14).map { "N\($0)[とても長いラベルのノード \($0)]" }.joined(separator: " --> ")
        let image = MermaidImage.image(for: "graph LR\n \(wide)")
        #expect(image != nil && image!.size.width <= MermaidImage.maxWidth)                      // 横に長い図は、縮める
        #expect(MermaidImage.image(for: "graph TD\n A --> B") != nil)
        #expect(MermaidImage.image(for: "gantt\n title x") == nil)
        #expect(MermaidImage.image(for: String(repeating: "a", count: MermaidImage.maxSource + 1)) == nil)   // 大きすぎる
    }

    @MainActor @Test func aMermaidBlockInMarkdownBecomesAnImageAttachmentButTheCopiedTextKeepsTheSource() {
        let markdown = "前\n\n```mermaid\ngraph TD\n A --> B\n```\n\n後"
        let rendered = MarkdownRenderer.render(markdown)
        var attachments = 0
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in if value != nil { attachments += 1 } }
        #expect(attachments == 1)
        #expect(!rendered.string.contains("graph TD"))                                            // コードは、画像に置き換わる
        #expect(MarkdownRenderer.plainText(markdown).contains("graph TD"))                       // コピーするのは、元の文字
        // 描けない図は、コードのまま
        let code = MarkdownRenderer.render("```mermaid\ngantt\n title x\n```")
        #expect(code.string.contains("gantt"))
    }
}

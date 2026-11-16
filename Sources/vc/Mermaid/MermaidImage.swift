import AppKit
import Foundation

/// Mermaid の図を、**画像**にする（暗いガラスの上で読める色。`MarkdownRenderer` が、コードブロックの代わりに、文章の中へ置く）。
/// **この Mac の中で、自前で描く**（外のライブラリ・JavaScript・ネットワークなし）。解析できない・大きすぎる図は、`nil`（呼び出し側は、コードのまま見せる）。
@MainActor enum MermaidImage {
    static let font = NSFont.systemFont(ofSize: 13)
    /// 図の最大の幅（これを超えたら、縮める）。
    static let maxWidth: CGFloat = 560
    /// 受け付ける、文字数・ノード数の上限（異常に大きい図は、描かない）。
    static let maxSource = 6000
    static let maxNodes = 60

    static func image(for source: String) -> NSImage? {
        guard source.count <= maxSource, let diagram = MermaidDiagram.parse(source) else { return nil }
        switch diagram {
        case .flow(let graph):
            guard graph.nodes.count <= maxNodes else { return nil }
            let layout = FlowLayout.make(graph, measure: measure)
            return make(size: layout.size) { drawFlow(layout) }
        case .sequence(let sequence):
            guard sequence.participants.count <= 12, sequence.items.count <= 120 else { return nil }
            let layout = SequenceLayout.make(sequence, measure: measure)
            return make(size: layout.size) { drawSequence(layout) }
        case .pie(let chart):
            guard chart.slices.count <= 16 else { return nil }
            let size = pieSize(chart)
            return make(size: size) { drawPie(chart, size: size) }
        }
    }

    /// 文字の大きさ（改行で、複数行）。
    static func measure(_ text: String) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let rect = (text as NSString).boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// 描く内容から、画像を作る（幅が上限を超えたら、縮める。向きは、上から下）。
    private static func make(size: CGSize, draw: @escaping @MainActor () -> Void) -> NSImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let scale = min(1, maxWidth / size.width)
        let image = NSImage(size: CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale)), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: scale, y: scale)
            MainActor.assumeIsolated { draw() }
            return true
        }
        return image
    }

    // MARK: 色

    private static let ink = NSColor(white: 1, alpha: 0.92)
    private static let line = NSColor(white: 1, alpha: 0.62)
    private static let fill = NSColor(white: 1, alpha: 0.09)
    private static let tint = NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.82, alpha: 1)

    private static func drawText(_ text: String, center: CGPoint, color: NSColor? = nil, size: CGFloat = 13, weight: NSFont.Weight = .regular) {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? ink, .paragraphStyle: style]
        let measured = (text as NSString).boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin], attributes: attributes)
        let rect = CGRect(x: center.x - ceil(measured.width) / 2 - 2, y: center.y - ceil(measured.height) / 2, width: ceil(measured.width) + 4, height: ceil(measured.height))
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    // MARK: フローチャート

    private static func drawFlow(_ layout: FlowLayout) {
        for placed in layout.edges { drawEdge(placed) }
        for placed in layout.nodes { drawNode(placed) }
    }

    private static func nodePath(_ node: FlowGraph.Node, _ f: CGRect) -> NSBezierPath {
        switch node.shape {
        case .rect, .subroutine: return NSBezierPath(roundedRect: f, xRadius: 4, yRadius: 4)
        case .round: return NSBezierPath(roundedRect: f, xRadius: 10, yRadius: 10)
        case .stadium: return NSBezierPath(roundedRect: f, xRadius: f.height / 2, yRadius: f.height / 2)
        case .circle, .startDot, .endDot: return NSBezierPath(ovalIn: f)
        case .diamond:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: f.midX, y: f.minY)); path.line(to: CGPoint(x: f.maxX, y: f.midY))
            path.line(to: CGPoint(x: f.midX, y: f.maxY)); path.line(to: CGPoint(x: f.minX, y: f.midY)); path.close()
            return path
        case .hexagon:
            let inset = min(16, f.width / 4)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: f.minX + inset, y: f.minY)); path.line(to: CGPoint(x: f.maxX - inset, y: f.minY)); path.line(to: CGPoint(x: f.maxX, y: f.midY))
            path.line(to: CGPoint(x: f.maxX - inset, y: f.maxY)); path.line(to: CGPoint(x: f.minX + inset, y: f.maxY)); path.line(to: CGPoint(x: f.minX, y: f.midY)); path.close()
            return path
        case .parallelogram:
            let skew: CGFloat = 12
            let path = NSBezierPath()
            path.move(to: CGPoint(x: f.minX + skew, y: f.minY)); path.line(to: CGPoint(x: f.maxX, y: f.minY))
            path.line(to: CGPoint(x: f.maxX - skew, y: f.maxY)); path.line(to: CGPoint(x: f.minX, y: f.maxY)); path.close()
            return path
        }
    }

    private static func drawNode(_ placed: FlowLayout.PlacedNode) {
        let f = placed.frame
        let path = nodePath(placed.node, f)
        switch placed.node.shape {
        case .startDot:
            ink.setFill(); path.fill(); return
        case .endDot:
            line.setStroke(); path.lineWidth = 1.6; path.stroke()
            ink.setFill(); NSBezierPath(ovalIn: f.insetBy(dx: 4.5, dy: 4.5)).fill(); return
        default: break
        }
        fill.setFill(); path.fill()
        line.setStroke(); path.lineWidth = 1.4; path.stroke()
        if placed.node.shape == .subroutine {
            let bars = NSBezierPath()
            for x in [f.minX + 8, f.maxX - 8] { bars.move(to: CGPoint(x: x, y: f.minY)); bars.line(to: CGPoint(x: x, y: f.maxY)) }
            bars.lineWidth = 1; bars.stroke()
        }
        drawText(placed.node.label, center: CGPoint(x: f.midX, y: f.midY))
    }

    private static func drawEdge(_ placed: FlowLayout.PlacedEdge) {
        let points = placed.points
        guard points.count >= 2 else { return }
        let edge = placed.edge
        let path = NSBezierPath()
        path.move(to: points[0])
        if points.count == 2 { path.line(to: points[1]) }
        else {
            for i in 1..<(points.count - 1) {
                let end = i == points.count - 2 ? points[points.count - 1] : CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                path.curve(to: end, controlPoint1: CGPoint(x: (path.currentPoint.x + 2 * points[i].x) / 3, y: (path.currentPoint.y + 2 * points[i].y) / 3), controlPoint2: CGPoint(x: (end.x + 2 * points[i].x) / 3, y: (end.y + 2 * points[i].y) / 3))
            }
        }
        line.setStroke()
        switch edge.line {
        case .solid: path.lineWidth = 1.4
        case .thick: path.lineWidth = 2.6
        case .dotted: path.lineWidth = 1.4; path.setLineDash([5, 4], count: 2, phase: 0)
        }
        path.stroke()
        drawEnd(edge.head, at: points[points.count - 1], from: points[points.count - 2])
        drawEnd(edge.tail, at: points[0], from: points[1])
        if let label = edge.label, let center = placed.labelCenter {
            let s = measure(label)
            let pill = CGRect(x: center.x - s.width / 2 - 6, y: center.y - s.height / 2 - 3, width: s.width + 12, height: s.height + 6)
            NSColor(calibratedWhite: 0.08, alpha: 0.82).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            drawText(label, center: center, size: 12)
        }
    }

    /// 線の端の印（矢じり・×・○）。`point`：端・`from`：線の、もう 1 つの側の点（向きを決める）。
    private static func drawEnd(_ end: FlowGraph.End, at point: CGPoint, from: CGPoint) {
        guard end != .none else { return }
        let angle = atan2(point.y - from.y, point.x - from.x)
        func rotated(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: point.x + dx * cos(angle) - dy * sin(angle), y: point.y + dx * sin(angle) + dy * cos(angle)) }
        switch end {
        case .arrow:
            let head = NSBezierPath()
            head.move(to: point); head.line(to: rotated(-10, -4.5)); head.line(to: rotated(-10, 4.5)); head.close()
            line.setFill(); head.fill()
        case .cross:
            let cross = NSBezierPath()
            cross.move(to: rotated(-8, -5)); cross.line(to: rotated(-1, 5)); cross.move(to: rotated(-8, 5)); cross.line(to: rotated(-1, -5))
            cross.lineWidth = 1.6; line.setStroke(); cross.stroke()
        case .circle:
            let center = rotated(-5, 0)
            let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            ring.lineWidth = 1.4; line.setStroke(); ring.stroke()
        case .none: break
        }
    }

    // MARK: シーケンス図

    private static func drawSequence(_ layout: SequenceLayout) {
        // 枠（loop・alt…）は、いちばん後ろ
        for frame in layout.frames {
            let path = NSBezierPath(roundedRect: frame.rect, xRadius: 4, yRadius: 4)
            NSColor(white: 1, alpha: 0.04).setFill(); path.fill()
            NSColor(white: 1, alpha: 0.34).setStroke(); path.lineWidth = 1; path.stroke()
            let tab = (frame.kind as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
            let tabRect = CGRect(x: frame.rect.minX, y: frame.rect.minY, width: tab.width + 14, height: 18)
            NSColor(white: 1, alpha: 0.18).setFill(); NSBezierPath(roundedRect: tabRect, xRadius: 4, yRadius: 4).fill()
            drawText(frame.kind, center: CGPoint(x: tabRect.midX, y: tabRect.midY), size: 11, weight: .semibold)
            if !frame.label.isEmpty { drawText("[\(frame.label)]", center: CGPoint(x: tabRect.maxX + 8 + measure("[\(frame.label)]").width / 2, y: tabRect.midY), color: NSColor(white: 1, alpha: 0.7), size: 11) }
            for divider in frame.dividers {
                let dash = NSBezierPath()
                dash.move(to: CGPoint(x: frame.rect.minX, y: divider.y)); dash.line(to: CGPoint(x: frame.rect.maxX, y: divider.y))
                dash.setLineDash([5, 4], count: 2, phase: 0); dash.lineWidth = 1; NSColor(white: 1, alpha: 0.34).setStroke(); dash.stroke()
                if !divider.label.isEmpty { drawText("[\(divider.label)]", center: CGPoint(x: frame.rect.minX + 14 + measure("[\(divider.label)]").width / 2, y: divider.y + 11), color: NSColor(white: 1, alpha: 0.7), size: 11) }
            }
        }
        // 生命線
        for x in layout.lifelineX {
            let life = NSBezierPath()
            life.move(to: CGPoint(x: x, y: layout.lifelineRange.lowerBound)); life.line(to: CGPoint(x: x, y: layout.lifelineRange.upperBound))
            life.setLineDash([4, 4], count: 2, phase: 0); life.lineWidth = 1; NSColor(white: 1, alpha: 0.28).setStroke(); life.stroke()
        }
        for box in layout.topBoxes + layout.bottomBoxes {
            let path = NSBezierPath(roundedRect: box.frame, xRadius: box.isActor ? box.frame.height / 2 : 5, yRadius: box.isActor ? box.frame.height / 2 : 5)
            fill.setFill(); path.fill(); line.setStroke(); path.lineWidth = 1.4; path.stroke()
            drawText(box.text, center: CGPoint(x: box.frame.midX, y: box.frame.midY), weight: .medium)
        }
        for note in layout.notes {
            let path = NSBezierPath(roundedRect: note.frame, xRadius: 4, yRadius: 4)
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.4, alpha: 0.16).setFill(); path.fill()
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.4, alpha: 0.6).setStroke(); path.lineWidth = 1; path.stroke()
            drawText(note.text, center: CGPoint(x: note.frame.midX, y: note.frame.midY), size: 12)
        }
        for m in layout.messages {
            let path = NSBezierPath()
            if m.isSelf {
                path.move(to: CGPoint(x: m.from, y: m.y - 14)); path.line(to: CGPoint(x: m.from + 36, y: m.y - 14)); path.line(to: CGPoint(x: m.from + 36, y: m.y + 6)); path.line(to: CGPoint(x: m.from, y: m.y + 6))
            } else {
                path.move(to: CGPoint(x: m.from, y: m.y)); path.line(to: CGPoint(x: m.to, y: m.y))
            }
            if m.dashed { path.setLineDash([5, 4], count: 2, phase: 0) }
            path.lineWidth = 1.4; line.setStroke(); path.stroke()
            if m.isSelf { drawEnd(m.head == .none ? .none : m.head, at: CGPoint(x: m.from, y: m.y + 6), from: CGPoint(x: m.from + 36, y: m.y + 6)) }
            else { drawEnd(m.head, at: CGPoint(x: m.to, y: m.y), from: CGPoint(x: m.from, y: m.y)) }
            if !m.text.isEmpty { drawText(m.text, center: m.textCenter, size: 12) }
        }
    }

    // MARK: 円グラフ

    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.82, alpha: 1), NSColor(calibratedRed: 0.38, green: 0.55, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.70, green: 0.50, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.50, blue: 0.70, alpha: 1), NSColor(calibratedRed: 0.98, green: 0.65, blue: 0.35, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.50, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.85, blue: 0.40, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.45, alpha: 1),
    ]

    private static func pieSize(_ chart: PieChart) -> CGSize {
        let legend = chart.slices.map { measure("\($0.label)  100.0%").width + 28 }.max() ?? 80
        let titleHeight: CGFloat = chart.title == nil ? 0 : 28
        return CGSize(width: 16 + 190 + 24 + legend + 16, height: max(16 + titleHeight + 190 + 16, 32 + titleHeight + CGFloat(chart.slices.count) * 22))
    }

    private static func drawPie(_ chart: PieChart, size: CGSize) {
        let titleHeight: CGFloat = chart.title == nil ? 0 : 28
        if let title = chart.title { drawText(title, center: CGPoint(x: size.width / 2, y: 20), size: 14, weight: .semibold) }
        let center = CGPoint(x: 16 + 95, y: 16 + titleHeight + 95)
        let total = chart.slices.reduce(0) { $0 + $1.value }
        var start: CGFloat = -90   // 上から、時計回り（画像は、上が 0 の座標：角度は、そのまま）
        for (i, slice) in chart.slices.enumerated() {
            let sweep = CGFloat(slice.value / total) * 360
            let path = NSBezierPath()
            path.move(to: center)
            path.appendArc(withCenter: center, radius: 95, startAngle: start, endAngle: start + sweep, clockwise: false)
            path.close()
            palette[i % palette.count].setFill(); path.fill()
            NSColor(white: 0, alpha: 0.35).setStroke(); path.lineWidth = 1; path.stroke()
            start += sweep
            let y = 16 + titleHeight + 12 + CGFloat(i) * 22
            palette[i % palette.count].setFill(); NSBezierPath(roundedRect: CGRect(x: 16 + 190 + 24, y: y - 6, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
            let text = "\(slice.label)  \(String(format: "%.1f", slice.value / total * 100))%"
            let width = measure(text).width
            drawText(text, center: CGPoint(x: 16 + 190 + 24 + 20 + width / 2, y: y), size: 12)
        }
    }
}

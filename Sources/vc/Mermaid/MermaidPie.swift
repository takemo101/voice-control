import AppKit
import Foundation

/// 円グラフ（`pie`）：BeautifulMermaid が、円グラフに対応していないので、自前で描く（小さい）。解析できなければ `nil`（コードのまま）。
struct PieChart {
    var title: String?
    var slices: [(label: String, value: Double)] = []

    /// `pie [showData] [title 題]` と、`"名前" : 数` の行。
    static func parse(_ source: String) -> PieChart? {
        let lines = source.components(separatedBy: "\n").map { line -> String in
            var text = line
            if let comment = text.range(of: "%%") { text = String(text[..<comment.lowerBound]) }
            return text.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard let header = lines.first, header.lowercased().hasPrefix("pie") else { return nil }
        var chart = PieChart()
        if let range = header.range(of: "title ", options: .caseInsensitive) { chart.title = String(header[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("title ") { chart.title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
            if line.lowercased().hasPrefix("showdata") { continue }
            guard let colon = line.lastIndex(of: ":"), let value = Double(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
            var label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if label.hasPrefix("\""), label.hasSuffix("\""), label.count >= 2 { label = String(label.dropFirst().dropLast()) }
            chart.slices.append((label, value))
        }
        return chart.slices.isEmpty || chart.slices.count > 16 || chart.slices.reduce(0, { $0 + $1.value }) <= 0 ? nil : chart
    }
}

@MainActor enum PieDrawing {
    private static let font = NSFont.systemFont(ofSize: 12)
    private static let ink = NSColor(white: 1, alpha: 0.92)
    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.82, alpha: 1), NSColor(calibratedRed: 0.38, green: 0.55, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.70, green: 0.50, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.50, blue: 0.70, alpha: 1), NSColor(calibratedRed: 0.98, green: 0.65, blue: 0.35, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.50, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.85, blue: 0.40, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.45, alpha: 1),
    ]

    private static func width(of text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }

    static func size(_ chart: PieChart) -> CGSize {
        let legend = chart.slices.map { width(of: "\($0.label)  100.0%") + 28 }.max() ?? 80
        let titleHeight: CGFloat = chart.title == nil ? 0 : 28
        return CGSize(width: 16 + 190 + 24 + legend + 16, height: max(16 + titleHeight + 190 + 16, 32 + titleHeight + CGFloat(chart.slices.count) * 22))
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat = 12, weight: NSFont.Weight = .regular, centered: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink]
        let measured = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: CGPoint(x: centered ? point.x - measured.width / 2 : point.x, y: point.y - measured.height / 2), withAttributes: attributes)
    }

    static func draw(_ chart: PieChart, size: CGSize) {
        let titleHeight: CGFloat = chart.title == nil ? 0 : 28
        if let title = chart.title { text(title, at: CGPoint(x: size.width / 2, y: 20), size: 14, weight: .semibold, centered: true) }
        let center = CGPoint(x: 16 + 95, y: 16 + titleHeight + 95)
        let total = chart.slices.reduce(0) { $0 + $1.value }
        var start: CGFloat = -90
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
            text("\(slice.label)  \(String(format: "%.1f", slice.value / total * 100))%", at: CGPoint(x: 16 + 190 + 24 + 20, y: y))
        }
    }
}

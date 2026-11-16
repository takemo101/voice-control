import Foundation

/// Mermaid の図を、**この Mac の中で、自前で描く**ための、解析（外部のライブラリ・JavaScript・ネットワークは、使わない）。
/// 対応：フローチャート（`graph`・`flowchart`）・状態遷移図（`stateDiagram`。入れ子の状態は除く）・シーケンス図（`sequenceDiagram`）・円グラフ（`pie`）。
/// **解析できない（対応しない種類・知らない書き方）ときは、`nil`**：呼び出し側は、これまでどおり、コードとして見せる（間違った図を出さない）。
enum MermaidDiagram: Equatable {
    case flow(FlowGraph)
    case sequence(SequenceDiagram)
    case pie(PieChart)

    static func parse(_ source: String) -> MermaidDiagram? {
        let lines = source.components(separatedBy: "\n").map { line -> String in
            var text = line
            if let comment = text.range(of: "%%") { text = String(text[..<comment.lowerBound]) }   // コメント
            return text.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard let header = lines.first else { return nil }
        let head = header.lowercased()
        let body = Array(lines.dropFirst())
        if head.hasPrefix("graph") || head.hasPrefix("flowchart") { return FlowParser.parse(header: header, body: body).map(MermaidDiagram.flow) }
        if head.hasPrefix("statediagram") { return FlowParser.parseState(body: body).map(MermaidDiagram.flow) }
        if head == "sequencediagram" { return SequenceParser.parse(body).map(MermaidDiagram.sequence) }
        if head.hasPrefix("pie") { return PieParser.parse(header: header, body: body).map(MermaidDiagram.pie) }
        return nil
    }
}

// MARK: フローチャート

struct FlowGraph: Equatable {
    enum Direction: Equatable { case topDown, leftRight, bottomUp, rightLeft }
    enum Shape: Equatable { case rect, round, stadium, circle, diamond, hexagon, subroutine, parallelogram, startDot, endDot }
    enum Line: Equatable { case solid, dotted, thick }
    enum End: Equatable { case none, arrow, cross, circle }
    struct Node: Equatable { var id: String; var label: String; var shape: Shape }
    struct Edge: Equatable { var from: String; var to: String; var label: String?; var line: Line; var head: End; var tail: End }
    var direction: Direction = .topDown
    var nodes: [Node] = []
    var edges: [Edge] = []

    mutating func node(_ id: String, label: String? = nil, shape: Shape? = nil) {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            if let label { nodes[index].label = label }
            if let shape { nodes[index].shape = shape }
        } else {
            nodes.append(Node(id: id, label: label ?? id, shape: shape ?? .rect))
        }
    }
}

enum FlowParser {
    static func parse(header: String, body: [String]) -> FlowGraph? {
        var graph = FlowGraph()
        let words = header.replacingOccurrences(of: ";", with: "").split(separator: " ").map { $0.uppercased() }
        if words.count > 1 {
            switch words[1] {
            case "TD", "TB": graph.direction = .topDown
            case "LR": graph.direction = .leftRight
            case "BT": graph.direction = .bottomUp
            case "RL": graph.direction = .rightLeft
            default: return nil
            }
        }
        var subgraphDepth = 0
        for rawLine in body {
            for statement in rawLine.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !statement.isEmpty {
                let lower = statement.lowercased()
                if lower.hasPrefix("subgraph") { subgraphDepth += 1; continue }   // 枠は、描かない（中身は、ふつうに、並べる）
                if lower == "end" { subgraphDepth = max(0, subgraphDepth - 1); continue }
                if ["classdef", "class ", "style ", "linkstyle", "click ", "direction", "acctitle", "accdescr"].contains(where: { lower.hasPrefix($0) }) { continue }
                guard parseStatement(statement, into: &graph) else { return nil }
            }
        }
        return graph.nodes.isEmpty ? nil : graph
    }

    /// 1 つの文：`A --> B --> C`・`A & B --> C`・`A`（ノードだけ）。
    private static func parseStatement(_ text: String, into graph: inout FlowGraph) -> Bool {
        var scanner = Scanner(text)
        guard var previous = scanner.nodeGroup(into: &graph) else { return false }
        while true {
            scanner.skipSpaces()
            if scanner.atEnd { return true }
            guard let link = scanner.link(), let next = scanner.nodeGroup(into: &graph) else { return false }
            for from in previous { for to in next { graph.edges.append(FlowGraph.Edge(from: from, to: to, label: link.label, line: link.line, head: link.head, tail: link.tail)) } }
            previous = next
        }
    }

    /// 状態遷移図：`[*] --> A`・`A --> B : 名前`・`state "説明" as A`・`A : 説明`。入れ子（`{`）は、対応しない。
    static func parseState(body: [String]) -> FlowGraph? {
        var graph = FlowGraph()
        func state(_ name: String, from isSource: Bool) -> String {
            if name == "[*]" {
                if isSource { graph.node("__start", label: "", shape: .startDot); return "__start" }
                graph.node("__end", label: "", shape: .endDot); return "__end"
            }
            graph.node(name, shape: .round)
            return name
        }
        for line in body {
            let lower = line.lowercased()
            if line.contains("{") || line.contains("}") || lower.hasPrefix("--") || lower.hasPrefix("note") { return nil }
            if lower.hasPrefix("direction") {
                switch lower.split(separator: " ").last.map(String.init)?.uppercased() {
                case "LR": graph.direction = .leftRight
                case "RL": graph.direction = .rightLeft
                case "BT": graph.direction = .bottomUp
                default: graph.direction = .topDown
                }
                continue
            }
            if lower.hasPrefix("state ") {
                // state "説明" as 名前
                if let regex = try? NSRegularExpression(pattern: #"^state\s+"([^"]+)"\s+as\s+(\S+)$"#, options: .caseInsensitive),   // try?: 固定の式
                   let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let label = Range(m.range(at: 1), in: line), let id = Range(m.range(at: 2), in: line) {
                    graph.node(String(line[id]), label: String(line[label]), shape: .round)
                } else { graph.node(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces), shape: .round) }
                continue
            }
            if let arrow = line.range(of: "-->") {
                let left = String(line[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
                var right = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
                var label: String?
                if let colon = right.firstIndex(of: ":") { label = String(right[right.index(after: colon)...]).trimmingCharacters(in: .whitespaces); right = String(right[..<colon]).trimmingCharacters(in: .whitespaces) }
                guard !left.isEmpty, !right.isEmpty else { return nil }
                let from = state(left, from: true), to = state(right, from: false)
                graph.edges.append(FlowGraph.Edge(from: from, to: to, label: label, line: .solid, head: .arrow, tail: .none))
                continue
            }
            if let colon = line.firstIndex(of: ":") {   // 状態の説明
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                graph.node(name, label: text, shape: .round)
                continue
            }
            return nil
        }
        return graph.nodes.isEmpty ? nil : graph
    }

    /// 文を、左から読む小さな読み取り器。
    struct Scanner {
        let chars: [Character]
        var index = 0
        init(_ text: String) { chars = Array(text) }
        var atEnd: Bool { index >= chars.count }
        mutating func skipSpaces() { while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 } }
        func rest() -> String { String(chars[index...]) }

        /// `A`・`A[文字]`・`A & B & C`。ノードの id の並びを返す。
        mutating func nodeGroup(into graph: inout FlowGraph) -> [String]? {
            var ids: [String] = []
            while true {
                skipSpaces()
                guard let id = node(into: &graph) else { return nil }
                ids.append(id)
                skipSpaces()
                if index < chars.count, chars[index] == "&" { index += 1; continue }
                return ids
            }
        }

        private static func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        private mutating func node(into graph: inout FlowGraph) -> String? {
            let start = index
            while index < chars.count, Self.isIdentifier(chars[index]) { index += 1 }
            guard index > start else { return nil }
            let id = String(chars[start..<index])
            guard index < chars.count else { graph.node(id); return id }
            // 形：開き → 閉じ
            let shapes: [(open: String, close: String, shape: FlowGraph.Shape)] = [
                ("(((", ")))", .circle), ("((", "))", .circle), ("([", "])", .stadium), ("[[", "]]", .subroutine), ("[(", ")]", .rect),
                ("[/", "/]", .parallelogram), ("[\\", "\\]", .parallelogram), ("[/", "\\]", .parallelogram), ("[\\", "/]", .parallelogram),
                ("{{", "}}", .hexagon), ("(", ")", .round), ("[", "]", .rect), ("{", "}", .diamond), (">", "]", .rect),
            ]
            for candidate in shapes where matches(candidate.open) {
                let labelStart = index + candidate.open.count
                if let end = closing(candidate.close, from: labelStart) {
                    graph.node(id, label: Self.clean(String(chars[labelStart..<end])), shape: candidate.shape)
                    index = end + candidate.close.count
                    return id
                }
            }
            graph.node(id)
            return id
        }

        private func matches(_ text: String, at position: Int? = nil) -> Bool {
            let p = position ?? index
            let t = Array(text)
            return p + t.count <= chars.count && Array(chars[p..<p + t.count]) == t
        }

        /// 閉じの位置（引用符の中は、飛ばす）。
        private func closing(_ close: String, from start: Int) -> Int? {
            var i = start
            var quoted = false
            while i < chars.count {
                if chars[i] == "\"" { quoted.toggle() }
                if !quoted, matches(close, at: i) { return i }
                i += 1
            }
            return nil
        }

        static func clean(_ raw: String) -> String {
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
            text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            return text
        }

        /// 線：`-->`・`---`・`-.->`・`==>`・`--x`・`<-->`・`-->|文字|`・`-- 文字 -->`。
        mutating func link() -> (label: String?, line: FlowGraph.Line, head: FlowGraph.End, tail: FlowGraph.End)? {
            skipSpaces()
            let text = rest()
            func match(_ pattern: String) -> [String]? {
                guard let regex = try? NSRegularExpression(pattern: pattern),   // try?: 固定の式
                      let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
                return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            }
            // 線の上に書く文字：`-- 文字 -->`
            if let m = match(#"^(--|==|-\.)\s+([^\s>|=\-][^>]*?)\s+(-->|--->|---|==>|===|\.->|--x|--o)"#) {
                index += m[0].count
                return (Self.clean(m[2]), Self.line(of: m[3]), Self.end(of: m[3], tailSide: false), .none)
            }
            if let m = match(#"^(<?)(-{2,}[>xo]?|={2,}>?|-\.+-?>?|-\.+-|\.->)(\|([^|]*)\|)?"#) {
                index += m[0].count
                let label = m[4].isEmpty ? nil : Self.clean(m[4])
                return (label, Self.line(of: m[2]), Self.end(of: m[2], tailSide: false), m[1] == "<" ? .arrow : .none)
            }
            return nil
        }

        private static func line(of op: String) -> FlowGraph.Line { op.contains("=") ? .thick : (op.contains(".") ? .dotted : .solid) }
        private static func end(of op: String, tailSide: Bool) -> FlowGraph.End {
            switch op.last { case ">": return .arrow; case "x": return .cross; case "o": return .circle; default: return .none }
        }
    }
}

// MARK: シーケンス図

struct SequenceDiagram: Equatable {
    struct Participant: Equatable { var id: String; var label: String; var isActor: Bool }
    enum Item: Equatable {
        case message(from: String, to: String, text: String, dashed: Bool, head: FlowGraph.End)
        case note(over: [String], side: Side, text: String)
        case frameStart(kind: String, label: String)
        case frameElse(label: String)
        case frameEnd
    }
    enum Side: Equatable { case over, leftOf, rightOf }
    var participants: [Participant] = []
    var items: [Item] = []

    mutating func participant(_ id: String, label: String? = nil, isActor: Bool = false) {
        if let index = participants.firstIndex(where: { $0.id == id }) {
            if let label { participants[index].label = label }
        } else { participants.append(Participant(id: id, label: label ?? id, isActor: isActor)) }
    }
}

enum SequenceParser {
    static func parse(_ body: [String]) -> SequenceDiagram? {
        var diagram = SequenceDiagram()
        var open = 0
        let frames = ["loop", "alt", "opt", "par", "critical", "break", "rect"]
        for line in body {
            let lower = line.lowercased()
            if lower.hasPrefix("participant ") || lower.hasPrefix("actor ") {
                let isActor = lower.hasPrefix("actor ")
                let rest = String(line.dropFirst(isActor ? 6 : 12)).trimmingCharacters(in: .whitespaces)
                if let range = rest.range(of: " as ") { diagram.participant(String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces), label: FlowParser.Scanner.clean(String(rest[range.upperBound...])), isActor: isActor) }
                else { diagram.participant(rest, isActor: isActor) }
                continue
            }
            if ["activate ", "deactivate ", "autonumber", "title ", "box ", "create ", "destroy "].contains(where: { lower.hasPrefix($0) }) { continue }
            if lower == "end" { guard open > 0 else { return nil }; open -= 1; diagram.items.append(.frameEnd); continue }
            if let kind = frames.first(where: { lower.hasPrefix($0 + " ") || lower == $0 }) {
                open += 1
                diagram.items.append(.frameStart(kind: kind, label: String(line.dropFirst(kind.count)).trimmingCharacters(in: .whitespaces))); continue
            }
            if lower.hasPrefix("else") || lower.hasPrefix("and ") {
                diagram.items.append(.frameElse(label: lower.hasPrefix("else") ? String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces) : String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))); continue
            }
            if lower.hasPrefix("note ") {
                // Note over A,B: 文字 / Note left of A: 文字 / Note right of A: 文字
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let head = String(line[line.index(line.startIndex, offsetBy: 5)..<colon]).trimmingCharacters(in: .whitespaces)
                let text = FlowParser.Scanner.clean(String(line[line.index(after: colon)...]))
                let lowerHead = head.lowercased()
                let side: SequenceDiagram.Side = lowerHead.hasPrefix("left of") ? .leftOf : (lowerHead.hasPrefix("right of") ? .rightOf : .over)
                let names = String(head.dropFirst(lowerHead.hasPrefix("left of") ? 7 : (lowerHead.hasPrefix("right of") ? 8 : 4))).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !names.isEmpty else { return nil }
                names.forEach { diagram.participant($0) }
                diagram.items.append(.note(over: names, side: side, text: text)); continue
            }
            // メッセージ：A->>B: 文字
            guard let parts = parseMessage(line) else { return nil }
            diagram.participant(parts.from); diagram.participant(parts.to)
            diagram.items.append(.message(from: parts.from, to: parts.to, text: parts.text, dashed: parts.dashed, head: parts.head))
        }
        return open == 0 && !diagram.participants.isEmpty ? diagram : nil
    }

    private static func parseMessage(_ line: String) -> (from: String, to: String, text: String, dashed: Bool, head: FlowGraph.End)? {
        let ops = ["<<-->>", "<<->>", "-->>", "->>", "--x", "-x", "--)", "-)", "-->", "->"]
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let left = String(line[..<colon]), text = FlowParser.Scanner.clean(String(line[line.index(after: colon)...]))
        for op in ops {
            guard let range = left.range(of: op) else { continue }
            let from = String(left[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            var to = String(left[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if to.hasPrefix("+") || to.hasPrefix("-") { to.removeFirst() }
            guard !from.isEmpty, !to.isEmpty else { return nil }
            let head: FlowGraph.End = op.hasSuffix("x") ? .cross : (op == "->" || op == "-->" ? .none : .arrow)
            return (from, to, text, op.hasPrefix("--") || op == "<<-->>", head)
        }
        return nil
    }
}

// MARK: 円グラフ

struct PieChart: Equatable {
    var title: String?
    var slices: [(label: String, value: Double)] = []
    static func == (lhs: PieChart, rhs: PieChart) -> Bool { lhs.title == rhs.title && lhs.slices.map(\.label) == rhs.slices.map(\.label) && lhs.slices.map(\.value) == rhs.slices.map(\.value) }
}

enum PieParser {
    static func parse(header: String, body: [String]) -> PieChart? {
        var chart = PieChart()
        if let range = header.range(of: "title ", options: .caseInsensitive) { chart.title = String(header[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
        for line in body {
            if line.lowercased().hasPrefix("title ") { chart.title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
            if line.lowercased().hasPrefix("showdata") { continue }
            guard let colon = line.lastIndex(of: ":"), let value = Double(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
            var label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if label.hasPrefix("\""), label.hasSuffix("\""), label.count >= 2 { label = String(label.dropFirst().dropLast()) }
            chart.slices.append((label, value))
        }
        return chart.slices.isEmpty || chart.slices.reduce(0, { $0 + $1.value }) <= 0 ? nil : chart
    }
}

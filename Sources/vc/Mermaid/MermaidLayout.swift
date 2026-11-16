import CoreGraphics
import Foundation

/// Mermaid の図の、**配置**（純粋：文字の大きさは、`measure` で受ける。描くのは `MermaidImage`）。
/// フローチャート・状態遷移図は、層に分けて並べる（循環は、逆向きの線として、描く・長い線は、途中の目印を通す・同じ層の中は、つながった先の平均の位置へ寄せる）。**きれいな自動配置ではなく、読める配置**。

// MARK: フローチャート

struct FlowLayout {
    struct PlacedNode { var node: FlowGraph.Node; var frame: CGRect }
    struct PlacedEdge { var edge: FlowGraph.Edge; var points: [CGPoint]; var labelCenter: CGPoint? }
    var nodes: [PlacedNode] = []
    var edges: [PlacedEdge] = []
    var size = CGSize.zero

    static let margin: CGFloat = 16
    static let nodeSeparation: CGFloat = 36
    static let rankSeparation: CGFloat = 52

    /// ノードの大きさ（形ごと）。
    static func size(of node: FlowGraph.Node, measure: (String) -> CGSize) -> CGSize {
        let text = measure(node.label)
        switch node.shape {
        case .startDot: return CGSize(width: 14, height: 14)
        case .endDot: return CGSize(width: 20, height: 20)
        case .circle: let d = max(max(text.width, text.height) + 24, 44); return CGSize(width: d, height: d)
        case .diamond: return CGSize(width: max(text.width * 1.5 + 24, 76), height: max(text.height * 1.7 + 18, 54))
        case .hexagon: return CGSize(width: max(text.width + 48, 64), height: max(text.height + 22, 38))
        case .stadium: return CGSize(width: max(text.width + 40, 64), height: max(text.height + 22, 38))
        case .rect, .round, .subroutine, .parallelogram: return CGSize(width: max(text.width + 30, 56), height: max(text.height + 22, 38))
        }
    }

    static func make(_ graph: FlowGraph, measure: (String) -> CGSize) -> FlowLayout {
        let horizontal = graph.direction == .leftRight || graph.direction == .rightLeft
        let count = graph.nodes.count
        let indexOf = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($1.id, $0) })
        let natural = graph.nodes.map { size(of: $0, measure: measure) }
        // 配置の座標系は、「層の軸（縦）」と「層の中の軸（横）」。横向きの図は、大きさを入れ替えて、あとで、座標を入れ替える
        let frameSize = natural.map { horizontal ? CGSize(width: $0.height, height: $0.width) : $0 }

        // 線（自己ループは、別）。循環は、深さ優先で見つけた戻る線を、逆向きにして、層を決める
        struct Oriented { var from: Int; var to: Int; var reversed: Bool; var edge: Int }
        var adjacency = Array(repeating: [Int](), count: count)   // 線の番号
        for (i, edge) in graph.edges.enumerated() {
            guard let from = indexOf[edge.from], let to = indexOf[edge.to], from != to else { continue }
            adjacency[from].append(i)
        }
        var state = Array(repeating: 0, count: count)
        var backEdges = Set<Int>()
        func visit(_ v: Int) {
            state[v] = 1
            for e in adjacency[v] {
                guard let w = indexOf[graph.edges[e].to] else { continue }
                if state[w] == 1 { backEdges.insert(e) } else if state[w] == 0 { visit(w) }
            }
            state[v] = 2
        }
        for v in 0..<count where state[v] == 0 { visit(v) }
        var oriented: [Oriented] = []
        for (i, edge) in graph.edges.enumerated() {
            guard let from = indexOf[edge.from], let to = indexOf[edge.to], from != to else { continue }
            oriented.append(backEdges.contains(i) ? Oriented(from: to, to: from, reversed: true, edge: i) : Oriented(from: from, to: to, reversed: false, edge: i))
        }

        // 層：いちばん長い道（根から）
        var rank = Array(repeating: 0, count: count)
        var indegree = Array(repeating: 0, count: count)
        for o in oriented { indegree[o.to] += 1 }
        var queue = (0..<count).filter { indegree[$0] == 0 }
        var head = 0
        while head < queue.count {
            let v = queue[head]; head += 1
            for o in oriented where o.from == v {
                rank[o.to] = max(rank[o.to], rank[v] + 1)
                indegree[o.to] -= 1
                if indegree[o.to] == 0 { queue.append(o.to) }
            }
        }

        // 項目（ノードと、長い線の途中の目印）
        struct Item { var rank: Int; var width: CGFloat; var height: CGFloat; var node: Int? }
        var items: [Item] = (0..<count).map { Item(rank: rank[$0], width: frameSize[$0].width, height: frameSize[$0].height, node: $0) }
        var chains: [Int: [Int]] = [:]   // 線の番号 → 項目の並び（始点から終点。向きは、層の向き）
        var up = Array(repeating: [Int](), count: count), down = Array(repeating: [Int](), count: count)
        func link(_ a: Int, _ b: Int) {
            while up.count < items.count { up.append([]); down.append([]) }
            down[a].append(b); up[b].append(a)
        }
        for o in oriented {
            var chain = [o.from]
            var previous = o.from
            if rank[o.to] - rank[o.from] > 1 {
                for r in (rank[o.from] + 1)..<rank[o.to] {
                    items.append(Item(rank: r, width: 10, height: 0, node: nil))
                    up.append([]); down.append([])
                    let id = items.count - 1
                    link(previous, id); chain.append(id); previous = id
                }
            }
            link(previous, o.to); chain.append(o.to)
            chains[o.edge] = chain
        }
        while up.count < items.count { up.append([]); down.append([]) }

        // 層ごとの並び（最初は、ノードの出てくる順）。つながった先の位置の平均で、並べ替える
        let rankCount = (items.map(\.rank).max() ?? 0) + 1
        var order: [[Int]] = Array(repeating: [], count: rankCount)
        for (i, item) in items.enumerated() { order[item.rank].append(i) }
        var position = Array(repeating: 0, count: items.count)
        func reindex() { for r in order { for (p, i) in r.enumerated() { position[i] = p } } }
        reindex()
        for sweep in 0..<8 {
            let downward = sweep % 2 == 0
            let ranks = downward ? Array(1..<max(1, rankCount)) : Array((0..<max(0, rankCount - 1)).reversed())
            for r in ranks {
                let keyed = order[r].map { i -> (Int, Double) in
                    let neighbours = downward ? up[i] : down[i]
                    let key = neighbours.isEmpty ? Double(position[i]) : neighbours.map { Double(position[$0]) }.reduce(0, +) / Double(neighbours.count)
                    return (i, key)
                }
                order[r] = keyed.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map { $0.element.0 }
                reindex()
            }
        }

        // 層の中の位置：まず詰めて並べ、つながった先の平均へ寄せる（重ならないように、押す）
        var x = Array(repeating: CGFloat(0), count: items.count)
        for r in order {
            var cursor: CGFloat = 0
            for i in r { x[i] = cursor + items[i].width / 2; cursor += items[i].width + nodeSeparation }
            let shift = (r.last.map { x[$0] + items[$0].width / 2 } ?? 0) / 2
            for i in r { x[i] -= shift }
        }
        for pass in 0..<10 {
            let downward = pass % 2 == 0
            let ranks = downward ? Array(0..<rankCount) : Array((0..<rankCount).reversed())
            for r in ranks {
                let row = order[r]
                var desired = row.map { i -> CGFloat in
                    let neighbours = (downward ? up[i] : down[i]).isEmpty ? (downward ? down[i] : up[i]) : (downward ? up[i] : down[i])
                    return neighbours.isEmpty ? x[i] : neighbours.map { x[$0] }.reduce(0, +) / CGFloat(neighbours.count)
                }
                var placed = desired
                for (k, i) in row.enumerated() where k > 0 {
                    let previous = row[k - 1]
                    placed[k] = max(placed[k], placed[k - 1] + (items[previous].width + items[i].width) / 2 + nodeSeparation)
                }
                // 寄せた分を、全体で打ち消す（片側へ流れない）
                let drift = (placed.reduce(0, +) - desired.reduce(0, +)) / CGFloat(max(1, row.count))
                desired = placed.map { $0 - drift }
                for (k, i) in row.enumerated() { x[i] = desired[k] }
                for (k, i) in row.enumerated() where k > 0 {   // 打ち消したあとも、重ならない
                    let previous = row[k - 1]
                    x[i] = max(x[i], x[previous] + (items[previous].width + items[i].width) / 2 + nodeSeparation)
                }
            }
        }
        // 層の縦の位置
        var rankHeight = Array(repeating: CGFloat(0), count: rankCount)
        for item in items { rankHeight[item.rank] = max(rankHeight[item.rank], item.height) }
        var rankY = Array(repeating: CGFloat(0), count: rankCount)
        for r in 0..<rankCount {
            rankY[r] = r == 0 ? rankHeight[0] / 2 : rankY[r - 1] + rankHeight[r - 1] / 2 + rankSeparation + rankHeight[r] / 2
        }

        // 向きに合わせて、座標を変える
        func place(_ i: Int) -> CGPoint {
            let along = rankY[items[i].rank], across = x[i]
            switch graph.direction {
            case .topDown: return CGPoint(x: across, y: along)
            case .bottomUp: return CGPoint(x: across, y: -along)
            case .leftRight: return CGPoint(x: along, y: across)
            case .rightLeft: return CGPoint(x: -along, y: across)
            }
        }
        var layout = FlowLayout()
        var centers: [CGPoint] = []
        for i in 0..<count {
            let c = place(i)
            centers.append(c)
            layout.nodes.append(PlacedNode(node: graph.nodes[i], frame: CGRect(x: c.x - natural[i].width / 2, y: c.y - natural[i].height / 2, width: natural[i].width, height: natural[i].height)))
        }

        // 線
        for (e, edge) in graph.edges.enumerated() {
            guard let from = indexOf[edge.from], let to = indexOf[edge.to] else { continue }
            if from == to {   // 自己ループ：右側の小さな輪
                let f = layout.nodes[from].frame
                let pts = [CGPoint(x: f.maxX, y: f.midY - 8), CGPoint(x: f.maxX + 30, y: f.midY - 8), CGPoint(x: f.maxX + 30, y: f.midY + 8), CGPoint(x: f.maxX, y: f.midY + 8)]
                layout.edges.append(PlacedEdge(edge: edge, points: pts, labelCenter: CGPoint(x: f.maxX + 30, y: f.midY)))
                continue
            }
            guard let chain = chains[e] else { continue }
            var points = chain.map(place)
            if let o = oriented.first(where: { $0.edge == e }), o.reversed { points.reverse() }
            let fromFrame = layout.nodes[from], toFrame = layout.nodes[to]
            if points.count >= 2 {
                points[0] = boundary(of: fromFrame, toward: points[1])
                points[points.count - 1] = boundary(of: toFrame, toward: points[points.count - 2])
            }
            layout.edges.append(PlacedEdge(edge: edge, points: points, labelCenter: edge.label == nil ? nil : midpoint(points)))
        }

        // 同じ 2 つのノードの間に、線が複数ある（行きと帰り・同じ向きの重複）ときは、横にずらして、重ならないようにする
        var groups: [String: [Int]] = [:]   // 組（小さい番号-大きい番号）→ layout.edges の位置
        for (position, placed) in layout.edges.enumerated() {
            guard let a = indexOf[placed.edge.from], let b = indexOf[placed.edge.to], a != b else { continue }
            groups["\(min(a, b))-\(max(a, b))", default: []].append(position)
        }
        for (key, members) in groups where members.count > 1 {
            let ends = key.split(separator: "-").compactMap { Int($0) }
            guard ends.count == 2 else { continue }
            let a = layout.nodes[ends[0]].frame, b = layout.nodes[ends[1]].frame
            let length = max(0.001, hypot(b.midX - a.midX, b.midY - a.midY))
            let normal = CGPoint(x: -(b.midY - a.midY) / length, y: (b.midX - a.midX) / length)   // 向きは、組で固定（行きと帰りが、反対側へずれる）
            for (k, position) in members.enumerated() {
                let offset = (CGFloat(k) - CGFloat(members.count - 1) / 2) * 22
                layout.edges[position].points = layout.edges[position].points.map { CGPoint(x: $0.x + normal.x * offset, y: $0.y + normal.y * offset) }
                // 文字は、線の外側へ、文字の幅の半分だけ、さらにずらす（行きと帰りの文字が、重ならない）
                let labelSize = layout.edges[position].edge.label.map(measure) ?? .zero
                let half = abs(normal.x) * labelSize.width / 2 + abs(normal.y) * labelSize.height / 2 + 6
                let side: CGFloat = offset == 0 ? 0 : (offset > 0 ? 1 : -1)
                layout.edges[position].labelCenter = layout.edges[position].labelCenter.map { CGPoint(x: $0.x + normal.x * (offset + side * half), y: $0.y + normal.y * (offset + side * half)) }
            }
        }

        // 全体の大きさ：ノード・線・線の文字を含めて、余白を足し、原点へ寄せる
        var bounds = CGRect.null
        for n in layout.nodes { bounds = bounds.union(n.frame) }
        for e in layout.edges {
            for p in e.points { bounds = bounds.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
            if let c = e.labelCenter, let label = e.edge.label {
                let s = measure(label)
                bounds = bounds.union(CGRect(x: c.x - s.width / 2 - 6, y: c.y - s.height / 2 - 4, width: s.width + 12, height: s.height + 8))
            }
        }
        if bounds.isNull { bounds = .zero }
        let dx = margin - bounds.minX, dy = margin - bounds.minY
        for i in layout.nodes.indices { layout.nodes[i].frame = layout.nodes[i].frame.offsetBy(dx: dx, dy: dy) }
        for i in layout.edges.indices {
            layout.edges[i].points = layout.edges[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            layout.edges[i].labelCenter = layout.edges[i].labelCenter.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        }
        layout.size = CGSize(width: bounds.width + margin * 2, height: bounds.height + margin * 2)
        return layout
    }

    /// 枠線の上の点：中心から、`point` へ向かう線が、形の縁と交わる位置。
    static func boundary(of placed: PlacedNode, toward point: CGPoint) -> CGPoint {
        let frame = placed.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = point.x - center.x, dy = point.y - center.y
        guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return center }
        let hw = frame.width / 2, hh = frame.height / 2
        let t: CGFloat
        switch placed.node.shape {
        case .circle, .startDot, .endDot:
            t = hw / max(0.001, (dx * dx + dy * dy).squareRoot())
        case .diamond:
            t = 1 / max(0.001, abs(dx) / hw + abs(dy) / hh)
        default:
            t = min(abs(dx) > 0.001 ? hw / abs(dx) : .infinity, abs(dy) > 0.001 ? hh / abs(dy) : .infinity)
        }
        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    /// 折れ線の、長さで見た、真ん中。
    static func midpoint(_ points: [CGPoint]) -> CGPoint {
        guard points.count >= 2 else { return points.first ?? .zero }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = lengths.reduce(0, +) / 2
        for (i, length) in lengths.enumerated() {
            if remaining <= length || i == lengths.count - 1 {
                let t = length > 0 ? remaining / length : 0
                return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * t, y: points[i].y + (points[i + 1].y - points[i].y) * t)
            }
            remaining -= length
        }
        return points[0]
    }
}

// MARK: シーケンス図

struct SequenceLayout {
    struct Box { var text: String; var frame: CGRect; var isActor: Bool }
    struct Message { var from: CGFloat; var to: CGFloat; var y: CGFloat; var text: String; var dashed: Bool; var head: FlowGraph.End; var textCenter: CGPoint; var isSelf: Bool }
    struct Note { var frame: CGRect; var text: String }
    struct Frame { var rect: CGRect; var kind: String; var label: String; var dividers: [(y: CGFloat, label: String)] }
    var topBoxes: [Box] = []
    var bottomBoxes: [Box] = []
    var lifelineX: [CGFloat] = []
    var lifelineRange: ClosedRange<CGFloat> = 0...0
    var messages: [Message] = []
    var notes: [Note] = []
    var frames: [Frame] = []
    var size = CGSize.zero

    static let margin: CGFloat = 16

    static func make(_ diagram: SequenceDiagram, measure: (String) -> CGSize) -> SequenceLayout {
        var layout = SequenceLayout()
        let ids = diagram.participants.map(\.id)
        func column(_ id: String) -> Int? { ids.firstIndex(of: id) }
        let boxSizes = diagram.participants.map { p -> CGSize in let s = measure(p.label); return CGSize(width: max(s.width + 28, 80), height: max(s.height + 18, 34)) }
        // 柱の間隔：見出しの幅と、間にまたがる文字の長さから
        var gaps = Array(repeating: CGFloat(0), count: max(0, ids.count - 1))
        for k in gaps.indices { gaps[k] = max(130, (boxSizes[k].width + boxSizes[k + 1].width) / 2 + 24) }
        for item in diagram.items {
            switch item {
            case .message(let from, let to, let text, _, _):
                guard let a = column(from), let b = column(to), a != b else { continue }
                let lo = min(a, b), hi = max(a, b)
                let need = measure(text).width + 36
                let have = gaps[lo..<hi].reduce(0, +)
                if have < need { for k in lo..<hi { gaps[k] += (need - have) / CGFloat(hi - lo) } }
            case .note(let over, _, let text):
                if over.count == 2, let a = column(over[0]), let b = column(over[1]), a != b {
                    let lo = min(a, b), hi = max(a, b)
                    let need = measure(text).width + 24
                    let have = gaps[lo..<hi].reduce(0, +)
                    if have < need { for k in lo..<hi { gaps[k] += (need - have) / CGFloat(hi - lo) } }
                }
            default: break
            }
        }
        var xs: [CGFloat] = []
        var cursor = margin + (boxSizes.first?.width ?? 0) / 2 + 20   // 左の注釈・自己メッセージの分の余白
        for k in ids.indices { xs.append(cursor); if k < gaps.count { cursor += gaps[k] } }
        layout.lifelineX = xs
        let headerHeight = boxSizes.map(\.height).max() ?? 34
        for (k, p) in diagram.participants.enumerated() {
            layout.topBoxes.append(Box(text: p.label, frame: CGRect(x: xs[k] - boxSizes[k].width / 2, y: margin, width: boxSizes[k].width, height: headerHeight), isActor: p.isActor))
        }
        var y = margin + headerHeight + 26
        var open: [(kind: String, label: String, startY: CGFloat, dividers: [(CGFloat, String)])] = []
        let left = (xs.first ?? 0) - 56, right = (xs.last ?? 0) + 56
        for item in diagram.items {
            switch item {
            case .message(let from, let to, let text, let dashed, let head):
                guard let a = column(from), let b = column(to) else { continue }
                let textSize = text.isEmpty ? CGSize.zero : measure(text)
                if a == b {
                    let lineY = y + textSize.height + 4
                    layout.messages.append(Message(from: xs[a], to: xs[a], y: lineY, text: text, dashed: dashed, head: head, textCenter: CGPoint(x: xs[a] + 40 + textSize.width / 2, y: lineY - 4), isSelf: true))
                    y = lineY + 34
                } else {
                    let lineY = y + textSize.height + 6
                    layout.messages.append(Message(from: xs[a], to: xs[b], y: lineY, text: text, dashed: dashed, head: head, textCenter: CGPoint(x: (xs[a] + xs[b]) / 2, y: lineY - 6 - textSize.height / 2), isSelf: false))
                    y = lineY + 20
                }
            case .note(let over, let side, let text):
                let s = measure(text)
                let columns = over.compactMap(column)
                guard let first = columns.min(), let last = columns.max() else { continue }
                var width = max(s.width + 20, 90)
                var x0: CGFloat
                switch side {
                case .over: width = max(width, xs[last] - xs[first] + 60); x0 = (xs[first] + xs[last]) / 2 - width / 2
                case .leftOf: x0 = xs[first] - 10 - width
                case .rightOf: x0 = xs[last] + 10
                }
                x0 = max(x0, 4)
                let height = s.height + 14
                layout.notes.append(Note(frame: CGRect(x: x0, y: y, width: width, height: height), text: text))
                y += height + 16
            case .frameStart(let kind, let label):
                open.append((kind, label, y, []))
                y += 26
            case .frameElse(let label):
                if !open.isEmpty { open[open.count - 1].dividers.append((y, label)) }
                y += 24
            case .frameEnd:
                guard let frame = open.popLast() else { continue }
                let inset = CGFloat(open.count) * 10
                layout.frames.append(Frame(rect: CGRect(x: left + inset, y: frame.startY - 4, width: (right - left) - inset * 2, height: y - frame.startY + 4), kind: frame.kind, label: frame.label, dividers: frame.dividers.map { ($0.0, $0.1) }))
                y += 14
            }
        }
        let bottom = y + 6
        layout.lifelineRange = (margin + headerHeight)...bottom
        for (k, p) in diagram.participants.enumerated() {
            layout.bottomBoxes.append(Box(text: p.label, frame: CGRect(x: xs[k] - boxSizes[k].width / 2, y: bottom, width: boxSizes[k].width, height: headerHeight), isActor: p.isActor))
        }
        var maxX = (xs.last ?? 0) + (boxSizes.last?.width ?? 0) / 2
        for note in layout.notes { maxX = max(maxX, note.frame.maxX) }
        for m in layout.messages where m.isSelf { maxX = max(maxX, m.from + 44 + measure(m.text).width) }
        layout.size = CGSize(width: max(maxX + margin, right + margin), height: bottom + headerHeight + margin)
        return layout
    }
}

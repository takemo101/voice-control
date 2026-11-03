import Foundation

/// agent-desktop の snapshot の、要素 1 つ。
public struct UIElement: Sendable, Equatable {
    public let ref: String
    public let role: String
    public let name: String
    public let states: [String]
    public let actions: [String]
    /// 画面上の位置（snapshot を `--include-bounds` で取ったとき）。
    public let bounds: Rect?

    public init(ref: String, role: String, name: String, states: [String] = [], actions: [String] = [], bounds: Rect? = nil) {
        self.ref = ref; self.role = role; self.name = name; self.states = states; self.actions = actions; self.bounds = bounds
    }

    /// 選択肢の 1 行（名前がなければ、役割だけ）。
    public var option: String { name.isEmpty ? role : "\(role): \(name)" }
    public var isFocused: Bool { states.contains("focused") }
    public var canClick: Bool { actions.contains("Click") }
    /// 文字を入れられる要素（役割の名前は、agent-desktop の macOS の対応による）。
    public var isTextInput: Bool { Self.textRoles.contains(role) && actions.contains("TypeText") }
    public var isScrollable: Bool { Self.scrollRoles.contains(role) }

    static let textRoles: Set<String> = ["textfield", "textarea", "searchfield", "combobox", "securetextfield"]
    static let scrollRoles: Set<String> = ["scrollarea", "scrollview", "list", "table", "outline", "webarea"]
}

public struct Snapshot: Sendable, Equatable {
    public let app: String
    /// 木の順（上から下）の、名前のある要素と、文字入力・スクロールの対象。
    public let elements: [UIElement]
    /// 前面のウィンドウの矩形（位置の基準）。
    public let window: Rect?

    public init(app: String, elements: [UIElement], window: Rect? = nil) { self.app = app; self.elements = elements; self.window = window }
}

public enum SnapshotError: Error, Equatable { case notOK(code: String), malformed }

public enum SnapshotParser {
    static func rect(_ any: Any?) -> Rect? {
        guard let b = any as? [String: Any], let x = b["x"] as? Double, let y = b["y"] as? Double,
              let w = b["width"] as? Double, let h = b["height"] as? Double else { return nil }
        return Rect(x: x, y: y, width: w, height: h)
    }

    /// `agent-desktop snapshot -i --include-bounds` の JSON → `Snapshot`。
    /// 含める要素：押せる（`Click`）要素（名前が空でもよい：「右上のボタン」に使う）、文字入力、スクロールの対象。
    public static func parse(_ data: Data) throws -> Snapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SnapshotError.malformed }
        guard root["ok"] as? Bool == true else {
            throw SnapshotError.notOK(code: ((root["error"] as? [String: Any])?["code"] as? String) ?? "UNKNOWN")
        }
        guard let body = root["data"] as? [String: Any], let tree = body["tree"] as? [String: Any] else { throw SnapshotError.malformed }
        var out: [UIElement] = []
        func walk(_ node: [String: Any]) {
            if let ref = node["ref_id"] as? String, let role = node["role"] as? String {
                let element = UIElement(
                    ref: ref, role: role, name: (node["name"] as? String) ?? "",
                    states: (node["states"] as? [String]) ?? [], actions: (node["available_actions"] as? [String]) ?? [],
                    bounds: rect(node["bounds"]))
                // 大きさのない要素（画面に出ていない内部の部品）は、除く。
                let sized = element.bounds.map { $0.width > 0 && $0.height > 0 } ?? true
                let operable = sized && !element.states.contains("hidden") && !element.states.contains("disabled")
                if operable && (element.canClick || element.isTextInput || element.isScrollable) { out.append(element) }
            }
            for child in (node["children"] as? [[String: Any]]) ?? [] { walk(child) }
        }
        walk(tree)
        return Snapshot(app: (body["app"] as? String) ?? "", elements: out, window: rect(tree["bounds"]))
    }
}

/// 画面上の矩形（左上が原点・単位はポイント。agent-desktop の `--include-bounds`）。
public struct Rect: Sendable, Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

public extension UIElement {
    /// ウィンドウの中での、おおまかな位置（3 × 3：左上・上・右上・左・中央・右・左下・下・右下）。位置が分からなければ `nil`。
    func region(in window: Rect?) -> String? {
        guard let b = bounds, let w = window, w.width > 0, w.height > 0 else { return nil }
        let fx = (b.centerX - w.x) / w.width, fy = (b.centerY - w.y) / w.height
        let col = fx < 1.0 / 3 ? 0 : (fx < 2.0 / 3 ? 1 : 2)
        let row = fy < 1.0 / 3 ? 0 : (fy < 2.0 / 3 ? 1 : 2)
        let names = [["左上", "上", "右上"], ["左", "中央", "右"], ["左下", "下", "右下"]]
        return names[row][col]
    }
}

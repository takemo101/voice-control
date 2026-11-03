import Foundation

/// 実行した 1 手の記録（前の指示を、次の判断の文脈に使う）。**発話の文字は、持たない**（操作の名前だけ）。
public struct Executed: Sendable, Equatable {
    public let step: Step
    public let at: Date
    public init(step: Step, at: Date = Date()) { self.step = step; self.at = at }
}

public enum History {
    /// 文脈に使う、最大の古さ（秒）と件数。
    public static let maxAge: TimeInterval = 180
    public static let maxCount = 3

    /// 古いものを落とし、新しい `maxCount` 件にする。
    public static func recent(_ entries: [Executed], now: Date = Date()) -> [Executed] {
        Array(entries.filter { now.timeIntervalSince($0.at) <= maxAge }.suffix(maxCount))
    }
}

public extension Step {
    /// 操作の短い名前（選択肢の文・文脈の文に使う）。入れる文字は、含めない。
    var label: String {
        switch self {
        case .openApp(let name): return "アプリを開く: \(name)"
        case .click(let e): return "\(Planner.roleLabel(e.role))を押す: \(e.name)"
        case .type: return "文字を入力する"
        case .press(let s): return "キー操作: \(s.option)"
        case .scroll(let d, _): return d.option
        case .window(let a, _): return a.option
        case .search: return "検索する"
        case .element(let v, let e): return v.label(for: e)
        case .closeApp(let name): return "アプリを終了する: \(name)"
        }
    }

    /// 逆の操作（「さっきと逆」「戻して」）。決まらないものは `nil`。
    var inverse: Step? {
        switch self {
        case .scroll(let d, let e):
            let opposite: [ScrollDirection: ScrollDirection] = [.up: .down, .down: .up, .left: .right, .right: .left]
            return .scroll(opposite[d]!, e)
        case .window(let a, let app):
            switch a {
            case .maximize, .minimize: return .window(.restore, app: app)
            case .restore: return .window(.maximize, app: app)
            }
        case .press(let s):
            let pairs = ["cmd+z": "cmd+shift+z", "cmd+shift+z": "cmd+z", "cmd+leftbracket": "cmd+rightbracket", "cmd+rightbracket": "cmd+leftbracket",
                         "up": "down", "down": "up", "left": "right", "right": "left"]
            return pairs[s.combo].flatMap { combo in Shortcut.all.first { $0.combo == combo } }.map { .press($0) }
        case .element(let v, let e):
            let pairs: [ElementVerb: ElementVerb] = [.check: .uncheck, .uncheck: .check, .expand: .collapse, .collapse: .expand]
            return pairs[v].map { .element($0, e) }
        default: return nil
        }
    }

    /// いまの画面で、同じ操作ができるようにする（要素の参照は、画面を取り直すと変わるので、役割と名前で探し直す）。見つからなければ `nil`。
    func rebound(to snapshot: Snapshot) -> Step? {
        switch self {
        case .click(let e):
            return snapshot.elements.first { $0.role == e.role && $0.name == e.name && $0.canClick }.map { .click($0) }
        case .scroll(let d, let e):
            return snapshot.elements.first { $0.role == e.role && $0.name == e.name && $0.isScrollable }.map { .scroll(d, $0) }
        case .type: return nil   // 入れる文字を、繰り返さない
        case .search: return nil
        case .closeApp: return nil   // 終了を、繰り返さない
        case .element(let v, let e):
            return snapshot.elements.first { $0.role == e.role && $0.name == e.name && $0.actions.contains(v.requiredAction) }.map { .element(v, $0) }
        case .window(let a, _): return snapshot.app.isEmpty ? nil : .window(a, app: snapshot.app)
        case .openApp, .press: return self
        }
    }
}

/// 実行した手の記録（セッション内で共有する。非同期の処理から、安全に追記・読み出しできる）。
public final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Executed] = []

    public init() {}

    public var entries: [Executed] { lock.lock(); defer { lock.unlock() }; return items }

    public func append(_ entry: Executed) {
        lock.lock(); defer { lock.unlock() }
        items.append(entry)
        if items.count > 50 { items.removeFirst(items.count - 50) }   // 文脈に使うのは、新しい数件だけ。増え続けない。
    }
}

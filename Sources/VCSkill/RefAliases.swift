import Foundation

/// agent-desktop の参照（`@s17tb038elj2nz:e13`）は、長いランダムな文字列で、言語モデルが、写し間違える（`@s20:e18` に縮める：測定）。
/// 言語モデルには、短い別名（`@a1:e13`）を見せ、実行の直前に、元の参照に戻す。
/// `@unchecked Sendable` の理由：可変な状態（`byID`・`byAlias`）は、すべて `lock` で守る。
public final class RefAliases: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: String] = [:]      // 元の snapshot id → 別名
    private var byAlias: [String: String] = [:]   // 別名 → 元の snapshot id

    public init() {}

    private static func split(_ ref: String) -> (id: String, rest: String)? {
        guard ref.hasPrefix("@"), let colon = ref.firstIndex(of: ":") else { return nil }
        return (String(ref[ref.index(after: ref.startIndex)..<colon]), String(ref[colon...]))
    }

    /// `@元の id:e13` → `@a1:e13`。
    public func shorten(_ ref: String) -> String {
        guard let (id, rest) = Self.split(ref) else { return ref }
        lock.lock(); defer { lock.unlock() }
        if byID[id] == nil {
            let alias = "a\(byID.count + 1)"
            byID[id] = alias
            byAlias[alias] = id
        }
        return "@\(byID[id]!)\(rest)"
    }

    /// `@a1:e13` → `@元の id:e13`。別名でなければ、そのまま。
    public func expand(_ token: String) -> String {
        guard let (alias, rest) = Self.split(token) else { return token }
        lock.lock(); defer { lock.unlock() }
        return byAlias[alias].map { "@\($0)\(rest)" } ?? token
    }
}

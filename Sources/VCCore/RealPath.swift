import Foundation

/// 場所の、**実際の形**（シンボリックリンク・`..`・`/var` と `/private/var` の違いを解いたもの）。許可の判定・表示で、「作業フォルダの中か」を、取り違えないために使う。
/// `URL.resolvingSymlinksInPath` は、使わない：ある場所と、ない場所で、`/var` と `/private/var` の扱いが違い、作業フォルダの中を「外」と、取り違えた（検証記録）。
public enum RealPath {
    /// いま、ある場所の、実際の形。なければ nil。
    public static func existing(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// **これから作る場所**も、扱える形：いちばん近い、ある場所（親）を解いて、残りをつなぐ。どの親も解けなければ、整えただけの形。
    public static func eventual(_ path: String) -> String {
        var rest: [String] = []
        var current = (path as NSString).standardizingPath
        while true {
            if let resolved = existing(current) {
                return ([resolved] + rest.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
            }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty else { return (path as NSString).standardizingPath }
            rest.append((current as NSString).lastPathComponent)
            current = parent
        }
    }

    /// `path` が、`root`（実際の形）の中（または、そのもの）か。
    public static func isInside(_ path: String, root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
}

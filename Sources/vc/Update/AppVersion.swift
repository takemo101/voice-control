import Foundation

/// アプリの版（`0.5.7`・タグの `v0.5.7`）。数字の並びを、左から比べる（足りない桁は 0）。
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let parts: [Int]

    /// 読めない（数字とドット以外・空の桁・桁が 5 つ以上）ものは `nil`。先頭の `v`・`V` は、取る。
    init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), piece.allSatisfy(\.isNumber), let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        parts = numbers
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        for index in 0..<count {
            let x = index < a.parts.count ? a.parts[index] : 0
            let y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// 桁数が違っても、値が同じなら、同じ版（`0.5` ＝ `0.5.0`）。
    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

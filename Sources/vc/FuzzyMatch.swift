import Foundation

/// あいまい検索（**純粋**）：入力の文字が、**順に**（間が空いていてもよい）含まれる項目を残し、よく合う順に並べる。
/// - 空白で区切った語は、**すべて**含まれること（`son 5` → 「Sonnet 5.5」）。大文字・小文字・全角半角・濃点の違いは、区別しない。
/// - よく合う順：語が**そのまま**（連続して）含まれる > 連続した文字が多い > 語頭（先頭・`-`・`_`・`.`・`/`・空白の次）から合う > 早い位置から合う。同点は、元の順。
enum FuzzyMatch {
    /// 合い具合（高いほど、よく合う）。合わなければ nil。語が空なら 0。
    static func score(_ query: String, in text: String) -> Int? {
        let terms = normalized(query).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !terms.isEmpty else { return 0 }
        let haystack = Array(normalized(text))
        var total = 0
        for term in terms {
            guard let one = score(term: Array(term), in: haystack) else { return nil }
            total += one
        }
        return total
    }

    /// 絞り込み（よく合う順。語が空なら、そのまま）。`text`：検索の対象の文字（名前と値を、つなぐ）。
    static func filter<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        guard !normalized(query).trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.enumerated().compactMap { index, item -> (Int, Int, T)? in
            score(query, in: text(item)).map { ($0, index, item) }
        }
        .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        .map(\.2)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isBoundary(_ haystack: [Character], _ index: Int) -> Bool {
        index == 0 || "-_./[]() \t".contains(haystack[index - 1])
    }

    private static func score(term: [Character], in haystack: [Character]) -> Int? {
        guard !term.isEmpty else { return 0 }
        // そのまま含まれる（連続）：いちばん強い。語頭・早い位置ほど、高い
        if haystack.count >= term.count {
            for start in 0...(haystack.count - term.count) where Array(haystack[start..<start + term.count]) == term {
                return 1000 + term.count * 10 + (isBoundary(haystack, start) ? 50 : 0) - min(start, 40)
            }
        }
        // 順に含まれる（間が空いてもよい）：左から、最初に合う所
        var position = 0, score = 0, previous = -2
        for character in term {
            guard let found = (position..<haystack.count).first(where: { haystack[$0] == character }) else { return nil }
            score += found == previous + 1 ? 8 : 1
            if isBoundary(haystack, found) { score += 4 }
            previous = found
            position = found + 1
        }
        return score
    }
}

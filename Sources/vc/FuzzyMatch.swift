import Foundation

/// あいまい検索（**純粋**）：入力の文字が、**順に**（間が空いていてもよい）含まれる項目を残し、よく合う順に並べる。
/// - 空白で区切った語は、**すべて**含まれること（`son 5` → 「Sonnet 5.5」）。大文字・小文字・全角半角・濃点の違いは、区別しない。
/// - よく合う順：語が**そのまま**（連続して）含まれる > 連続した文字が多い > 語頭（先頭・`-`・`_`・`.`・`/`・空白の次）から合う > 早い位置から合う。同点は、元の順。
enum FuzzyMatch {
    /// 合った結果：点数（高いほど、よく合う）と、**合った文字の位置**（元の文字列の、何文字目か：表示で、強調する）。
    struct Match: Equatable {
        let score: Int
        let positions: Set<Int>
    }

    /// 合い具合。合わなければ nil。語が空なら、点数 0・位置なし。
    static func match(_ query: String, in text: String) -> Match? {
        let terms = terms(of: query)
        guard !terms.isEmpty else { return Match(score: 0, positions: []) }
        let haystack = folded(text)
        var total = 0
        var positions = Set<Int>()
        for term in terms {
            guard let one = best(term: term, in: haystack) else { return nil }
            total += one.score
            positions.formUnion(one.positions)
        }
        return Match(score: total, positions: positions)
    }

    static func score(_ query: String, in text: String) -> Int? { match(query, in: text)?.score }

    /// 強調する位置：**合った語だけ**（その文字列には合わない語は、無視する。名前と値を、別々に、強調するため）。
    static func highlight(_ query: String, in text: String) -> Set<Int> {
        let haystack = folded(text)
        return terms(of: query).reduce(into: Set<Int>()) { result, term in
            if let one = best(term: term, in: haystack) { result.formUnion(one.positions) }
        }
    }

    /// 絞り込み（よく合う順。語が空なら、そのまま）。`text`：検索の対象の文字（名前と値を、つなぐ）。
    static func filter<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        guard !terms(of: query).isEmpty else { return items }
        return items.enumerated().compactMap { index, item -> (Int, Int, T)? in
            score(query, in: text(item)).map { ($0, index, item) }
        }
        .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        .map(\.2)
    }

    // MARK: 内部

    private static func terms(of query: String) -> [[Character]] {
        folded(query).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "　" }).map(Array.init)
    }

    /// 1 文字ずつ、そろえる（元の位置と、ずれない：1 文字は、1 文字のまま）。
    private static func folded(_ text: String) -> [Character] {
        text.map { character in String(character).folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil).first ?? character }
    }

    private static func isBoundary(_ haystack: [Character], _ index: Int) -> Bool {
        index == 0 || "-_./[]() \t".contains(haystack[index - 1])
    }

    private static func best(term: [Character], in haystack: [Character]) -> Match? {
        guard !term.isEmpty else { return Match(score: 0, positions: []) }
        // そのまま含まれる（連続）：いちばん強い。語頭・早い位置ほど、高い（いちばん高い所を選ぶ）
        var contiguous: Match?
        if haystack.count >= term.count {
            for start in 0...(haystack.count - term.count) where Array(haystack[start..<start + term.count]) == term {
                let score = 1000 + term.count * 10 + (isBoundary(haystack, start) ? 50 : 0) - min(start, 40)
                if contiguous == nil || score > contiguous!.score { contiguous = Match(score: score, positions: Set(start..<start + term.count)) }
            }
        }
        if let contiguous { return contiguous }
        // 順に含まれる（間が空いてもよい）：左から、最初に合う所
        var position = 0, score = 0, previous = -2
        var found = Set<Int>()
        for character in term {
            guard let at = (position..<haystack.count).first(where: { haystack[$0] == character }) else { return nil }
            score += at == previous + 1 ? 8 : 1
            if isBoundary(haystack, at) { score += 4 }
            found.insert(at)
            previous = at
            position = at + 1
        }
        return Match(score: score, positions: found)
    }
}

/// モデルの一覧の、見せ方（**純粋**）：分け方・キーでの移動。
enum ModelListLogic {
    struct Section: Equatable {
        /// 見出し（なければ、分けない）。
        let title: String?
        let items: [Item]
    }

    /// 1 行（画面に出す、名前・値・説明）。
    struct Item: Equatable, Identifiable {
        let id: String
        let name: String
        let detail: String?
    }

    /// 分ける鍵：`提供元/モデル`（opencode）は提供元・`モデル[深さ]`（Codex）はモデル。なければ nil。
    static func groupKey(of id: String) -> String? {
        if let slash = id.firstIndex(of: "/"), slash != id.startIndex { return String(id[..<slash]) }
        if let bracket = id.firstIndex(of: "["), bracket != id.startIndex { return String(id[..<bracket]) }
        return nil
    }

    /// 検索の語がないとき、**2 つ以上の鍵があり、半分より多くが鍵を持てば**、鍵ごとに分ける（長い一覧：opencode 168 件・Codex 58 件）。鍵のないものは、最後の「そのほか」。
    /// 検索の語があるときは、分けない（よく合う順に、1 つの並び）。
    static func sections(_ items: [Item], query: String) -> [Section] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return [Section(title: nil, items: items)] }
        let keys = items.map { groupKey(of: $0.id) }
        let distinct = Set(keys.compactMap { $0 })
        guard distinct.count >= 2, keys.compactMap({ $0 }).count * 2 > items.count else { return [Section(title: nil, items: items)] }
        var order: [String] = []
        var byKey: [String: [Item]] = [:]
        var others: [Item] = []
        for (item, key) in zip(items, keys) {
            guard let key else { others.append(item); continue }
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.map { Section(title: $0, items: byKey[$0] ?? []) } + (others.isEmpty ? [] : [Section(title: "そのほか", items: others)])
    }

    /// キー（↑↓）で、強調する行を動かす：端で止まる（回らない）。まだ決まっていなければ、↓ は先頭・↑ は末尾。一覧が空なら nil。
    static func moved(from current: String?, by delta: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return delta >= 0 ? ids.first : ids.last }
        return ids[min(ids.count - 1, max(0, index + delta))]
    }
}

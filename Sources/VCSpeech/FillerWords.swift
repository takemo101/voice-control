import Foundation

/// つなぎ言葉（フィラー：「えーと」「um」など）の除去（`vc dictate`・音声入力で、入力する文字から）。
/// 辞書（利用者が足し引きできる語の一覧）を、文字列の一致で消すだけ（言語モデルは使わない）。VoiceInk と同じ考え方。
///
/// **一致の規則**（意味のある語を、巻き込まないため）：
/// - 英数字の語（`um`・`uh`）：前後が、単語の続きでないとき（`umbrella`・`uh-huh` は、そのまま）。大文字・小文字は、区別しない。
/// - それ以外の語（日本語）：スペースで区切れないので、**前が、文頭・空白・句読点のとき**に一致する。前が文字でも、**3 文字以上の語が、直後に読点・句点・空白・文末を伴うとき**（「今日はえーと、明日」）は、一致する。
///   2 文字の語（「えー」）は、前が文字のとき、一致しない（「ええー」の途中を、削らないため）。
/// - 消した語に付く読点・`…` も、一緒に消す。前に文字があって、読点が付いていたら、1 つ残す（「今日はえーと、明日」→「今日は、明日」）。
/// - 連続するつなぎ言葉（「えーと、えーと、」）は、まとめて消す。
/// 辞書に、ふつうの語の一部にもなる語（「あの」など）を足すと、その語も消える（文頭・句読点の直後だけ）。
public enum FillerWords {
    /// 既定の辞書。日本語は、つなぎ言葉だと、まず間違いない形だけ（「あの」「その」「まあ」は、ふつうの語でもあるので、入れない）。
    public static let defaults: [String] = [
        "えーっと", "ええっと", "えーと", "えっと", "ええと",
        "あのー", "あのう", "そのー", "うーんと", "うーん", "んー", "えー",
        "uh", "um", "uhm", "umm", "uhh", "hmm", "erm",
    ]

    /// 辞書の語として、使えない理由。
    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case empty
        case tooShort
        case tooLong
        case notAWord
        case tooMany
        case endsWithParticle

        public var description: String {
            switch self {
            case .empty: return "語が空です"
            case .tooShort: return "1 文字の語は、足せません（ふつうの語の一部を、消してしまうため）"
            case .tooLong: return "語が長すぎます（\(maxLength) 文字まで）"
            case .notAWord: return "文字（かな・漢字・英数字）を含む語にしてください"
            case .tooMany: return "語が多すぎます（\(maxCount) 語まで）"
            case .endsWithParticle: return "語の最後が、助詞（を・は・も・が・に）のようです。語だけを渡してください（例：「なんかを」ではなく「なんか」）"
            }
        }
    }

    public static let maxLength = 20
    public static let maxCount = 200

    /// 辞書に足す語の検査と整形（前後の空白を除き、途中の空白は 1 つにする）。外から来た文字（声・引数）は、ここで 1 回だけ検査する。
    public static func normalize(_ word: String) -> Result<String, Invalid> {
        // 濁点などを分けた形（言語モデルが、そう出すことがある）は、1 文字の形（NFC）にそろえる：保存する辞書の形を、1 つにする
        let collapsed = word.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if collapsed.isEmpty { return .failure(.empty) }
        if collapsed.contains(where: { $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }) { return .failure(.notAWord) }
        if collapsed.count < 2 { return .failure(.tooShort) }
        if collapsed.count > maxLength { return .failure(.tooLong) }
        if !collapsed.contains(where: { $0.isLetter || $0.isNumber }) { return .failure(.notAWord) }
        // 声から取り出した語に、助詞が付いてくることがある（「なんかを」）：誤って辞書に入らないよう、断る
        if collapsed.count >= 3, let last = collapsed.last, !last.isASCII, "をはもがに".contains(last) { return .failure(.endsWithParticle) }
        return .success(collapsed)
    }

    /// 設定の辞書（なければ、既定）。
    public static func list(setting: [String]?) -> [String] { setting ?? defaults }

    /// 音声入力で、つなぎ言葉を消すか（既定：消さない）。
    public static func isEnabled(setting: Bool?) -> Bool { setting ?? false }

    /// 辞書に足す。すでにあれば（大文字・小文字を区別せず）、変えない。
    public static func adding(_ word: String, to list: [String]) -> Result<(list: [String], added: Bool), Invalid> {
        switch normalize(word) {
        case let .failure(error): return .failure(error)
        case let .success(normalized):
            if list.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) { return .success((list, false)) }
            if list.count >= maxCount { return .failure(.tooMany) }
            return .success((list + [normalized], true))
        }
    }

    /// 辞書から外す（大文字・小文字を区別しない）。
    public static func removing(_ word: String, from list: [String]) -> (list: [String], removed: Bool) {
        let target = word.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let kept = list.filter { $0.caseInsensitiveCompare(target) != .orderedSame }
        return (kept, kept.count != list.count)
    }

    // MARK: 除去

    private static let commas: Set<Character> = ["、", "，", ",", "…"]
    private static let sentenceEnds: Set<Character> = ["。", "．", ".", "！", "？", "!", "?"]
    private static let boundaries: Set<Character> = ["、", "。", "，", "．", ",", ".", "!", "?", "！", "？", "…", "・", "「", "」", "『", "』", "（", "）", "(", ")", "“", "”", "\"", ":", ";", "：", "；"]

    private static func isWordish(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" || c == "'" || c == "’" }
    private static func isAsciiWord(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
    private static func isBoundary(_ c: Character) -> Bool { c.isWhitespace || boundaries.contains(c) }

    /// `text` から、`fillers` の語を消す。結果の前後の空白は、除く。
    public static func remove(from text: String, fillers: [String]) -> String {
        let words = fillers.compactMap { word -> (chars: [Character], lower: [Character], ascii: Bool)? in
            let chars = Array(word)
            guard !chars.isEmpty else { return nil }
            return (chars, Array(word.lowercased()), isAsciiWord(chars[0]) && isAsciiWord(chars[chars.count - 1]))
        }.sorted { $0.chars.count > $1.chars.count }   // 長い語を先に（「えーっと」を、「えー」より先に）
        guard !words.isEmpty, !text.isEmpty else { return text }

        let src = Array(text)
        let lower = Array(text.lowercased())
        let sameLength = lower.count == src.count   // 大文字・小文字の変換で、長さが変わる文字があれば、小文字の比較は使わない（原文のまま比べる）
        var out: [Character] = []
        var index = 0
        var justRemoved = false

        while index < src.count {
            guard let end = matchEnd(at: index, src: src, lower: sameLength ? lower : src, words: words, afterRemoval: justRemoved) else {
                out.append(src[index])
                index += 1
                justRemoved = false
                continue
            }
            // 消した語に付く、読点・`…`・`...`（と、文頭に残る句点）も、一緒に消す
            var next = skipInlineSpaces(end, src)
            var comma: Character?
            if next + 2 < src.count, src[next] == ".", src[next + 1] == ".", src[next + 2] == "." {
                comma = "…"
                next += 3
            } else if next < src.count, commas.contains(src[next]) {
                comma = src[next]
                next += 1
            } else if next < src.count, sentenceEnds.contains(src[next]), out.last.map({ sentenceEnds.contains($0) || commas.contains($0) || $0 == "\n" }) ?? true {
                next += 1
            }
            next = skipInlineSpaces(next, src)
            // 前に文字があるとき、区切りを残す：読点が付いていたら 1 つ（「今日はえーと、明日」→「今日は、明日」）。英数字の語どうしは、空白を 1 つ
            while out.last == " " { out.removeLast() }
            if let last = out.last, last != "\n", !isBoundary(last), let comma { out.append(comma) }
            if let last = out.last, last != "\n", !last.isWhitespace, next < src.count, isAsciiWord(src[next]), isAsciiWord(last) || last == "," || last == "." { out.append(" ") }
            index = next
            justRemoved = true
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func skipInlineSpaces(_ from: Int, _ src: [Character]) -> Int {
        var i = from
        while i < src.count, src[i].isWhitespace, src[i] != "\n" { i += 1 }
        return i
    }

    /// `index` から、辞書の語が一致するとき、その終わり（含まない位置）。
    private static func matchEnd(at index: Int, src: [Character], lower: [Character], words: [(chars: [Character], lower: [Character], ascii: Bool)],
                                 afterRemoval: Bool) -> Int? {
        let previous: Character? = index > 0 ? src[index - 1] : nil
        for word in words {
            let end = index + word.chars.count
            guard end <= src.count, Array(lower[index..<end]) == word.lower else { continue }
            let following: Character? = end < src.count ? src[end] : nil
            if word.ascii {
                if let previous, !afterRemoval, isWordish(previous) { continue }
                if let following, isWordish(following) { continue }
                return end
            }
            let previousOK = afterRemoval || previous == nil || isBoundary(previous!)
            let followingDelimited = following == nil || isBoundary(following!)
            if previousOK || (word.chars.count >= 3 && followingDelimited) { return end }
        }
        return nil
    }
}

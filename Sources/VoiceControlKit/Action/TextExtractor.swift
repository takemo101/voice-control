import Foundation

/// 「…」と入力して、の「…」を取り出す。Tiny-Jev は文章を作れないので、入れる文字は、話した文字そのまま。
/// 取り出し方：かぎ括弧（「」『』""）で囲んだ文字。なければ「<文字>と入力して」の形の、「と」の前。
public enum TextExtractor {
    private static let quoted = try! NSRegularExpression(pattern: "[「『“\"]([^」』”\"]+)[」』”\"]")
    // 「最近の流行という言葉を入力して」：「という」の前の、助詞（に・で・を・は・が）のあとから。
    private static let called = try! NSRegularExpression(pattern: "([^にでをはが、。]+)という(?:言葉|文字|単語|ワード|キーワード|テキスト|文章|文)?を?(?:入力|打|書|タイプ)")
    private static let beforeVerb = try! NSRegularExpression(pattern: "^(.+?)(?:と|って|を)(?:入力|打|書|タイプ)")

    public static func text(in utterance: String) -> String? {
        let range = NSRange(utterance.startIndex..., in: utterance)
        for regex in [quoted, called, beforeVerb] {
            if let m = regex.firstMatch(in: utterance, range: range), let r = Range(m.range(at: 1), in: utterance) {
                let t = String(utterance[r]).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }
}

public extension TextExtractor {
    private static let searchVerb = try! NSRegularExpression(pattern: "^(.+?)(?:を|について|のこと)?(?:検索|調べ|探し)")
    private static let leadingBy = try! NSRegularExpression(pattern: "^[^、で]{1,15}で(?=.)")

    /// 「最近の流行を検索して」の「最近の流行」。かぎ括弧があれば、その中。「Chromeで…を検索して」の、先頭の「…で」は外す。
    static func searchQuery(in utterance: String) -> String? {
        let range = NSRange(utterance.startIndex..., in: utterance)
        guard searchVerb.firstMatch(in: utterance, range: range) != nil else { return nil }
        if let quotedText = text(in: utterance) { return quotedText }
        guard let m = searchVerb.firstMatch(in: utterance, range: range), let r = Range(m.range(at: 1), in: utterance) else { return nil }
        var q = String(utterance[r])
        if let by = leadingBy.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)), let br = Range(by.range, in: q) { q.removeSubrange(br) }
        q = q.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? nil : q
    }
}

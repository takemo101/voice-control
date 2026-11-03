import Foundation

/// 「Chromeをアクティブにして、最大化して」のような、複数の依頼を、1 手ずつの文に分ける。
/// 分けるところ：句点（。）、「…て、」「…で、」の読点、「…てから」、「そのあと」「それから」「次に」「その後」「そして」、「…て」の直後に文が続く形。
/// 分けない：かぎ括弧（「」『』）の中、「ついて」「として」「しても」「してほしい」など。
/// 整える：「…してください」→「…して」、文頭の「まず」「そこで」「で、」を外す。
/// 読点・句点が認識結果に出ない言い方で、「…して」の直後が続かない形は、分けられない（1 手として扱う）。
public enum ClauseSplitter {
    private static let quoted = try! NSRegularExpression(pattern: "[「『“][^」』”]*[」』”]")
    private static let polite = try! NSRegularExpression(pattern: "(?<=[てで])(?:ください|下さい)")
    private static let leading = try! NSRegularExpression(pattern: "^(?:まず|そこで|それで|で、|あと、?)[、，,]?\\s*")
    // 1 番目の括弧（「て」）だけ、残す。他の区切りは、なくなる。
    private static let boundary = try! NSRegularExpression(pattern: "[。．.！？!?]+\\s*|(?<=[ていで])[、，,]\\s*|(?<!つい)(?<!よっ)(?<!とし)(?<!とっ)(?<!おい)(て)(?=(?!ください|下さい|ほしい|欲しい|もらえ|くれ|おき|いる|いた|ある|あげ|いただ|しま|くだ|から|も|は|い(?:ま|な|る|た))[^、，,。\\s」』）)])|(?<=て)から[、，,]?\\s*|(?:そのあと|その後|それから|次に|そして)に?[、，,]?\\s*")

    /// 読点で切れて、これだけが残った断片（「で、」「まず、」）は、捨てる。
    private static let fillers: Set<String> = ["で", "まず", "そこで", "それで", "あと", "次に", "そして"]

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    public static func split(_ utterance: String) -> [String] {
        // かぎ括弧の中身は、記号に置き換えて守る（前から順に番号を振る）。
        var protected: [String] = []
        var text = ""
        var cursor = utterance.startIndex
        for m in quoted.matches(in: utterance, range: NSRange(utterance.startIndex..., in: utterance)) {
            guard let r = Range(m.range, in: utterance) else { continue }
            text += utterance[cursor..<r.lowerBound] + "\u{1}\(protected.count)\u{1}"
            protected.append(String(utterance[r]))
            cursor = r.upperBound
        }
        text += utterance[cursor...]

        text = replace(polite, in: text, with: "")
        let marked = replace(boundary, in: text, with: "$1\u{0}")
        return marked.split(separator: "\u{0}").map { piece in
            var s = replace(leading, in: String(piece).trimmingCharacters(in: .whitespaces), with: "")
            for (i, q) in protected.enumerated() { s = s.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: q) }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !fillers.contains($0) }
    }
}

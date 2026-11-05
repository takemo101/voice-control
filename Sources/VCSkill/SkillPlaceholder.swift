import Foundation

/// スキルの本文（と `allowed-commands`）に書ける、`${名前}` の記号（大文字・数字・アンダースコア）。
/// - `${SKILL_DIR}`：そのスキルのディレクトリ。**読み込むときに**、本文と `allowed-commands` で置き換える（`SkillStore.expandSkillDir`）。
/// - `${USER_REQUEST}`：利用者の依頼（発話）。**実行するときに**、**本文だけ**で置き換える。
///   **`allowed-commands` には、書けない**（許可を、発話で変えられないように。許可の判断は、コードが、書いてあるとおりに行う）。
/// - 知らない名前（書き間違い）は、読み込みの失敗にする。小文字（`${home}`）は、記号ではない（そのまま）。
enum SkillPlaceholder {
    static let skillDir = "SKILL_DIR"
    static let userRequest = "USER_REQUEST"
    static let known: [String] = [skillDir, userRequest]

    private static let pattern = #"\$\{([A-Z][A-Z0-9_]*)\}"#

    /// 本文・コマンドの中の、知らない名前（重複なし・出てきた順）。
    static func unknownNames(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[r])
            if !known.contains(name), !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    /// `${USER_REQUEST}` を、発話を**データの囲み**に入れたものに置き換える（一度だけ。発話の中の記号は、置き換えない）。
    /// 発話の中の、囲みの閉じタグに見える文字は、無害にする（囲みを、破れないように）。囲みの中は、指示ではない（本文に、そう書く）。
    static func expand(_ body: String, request: String) -> String {
        let marker = "${\(userRequest)}"
        guard body.contains(marker) else { return body }
        let safe = request.replacingOccurrences(of: #"</\s*user_request\s*>"#, with: "[/user_request]", options: [.regularExpression, .caseInsensitive])
        return body.replacingOccurrences(of: marker, with: "<user_request>\n\(safe)\n</user_request>")
    }
}

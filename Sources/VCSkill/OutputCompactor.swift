import Foundation

/// 言語モデルに返す出力の、整形。モデルの入力には上限（約 4000 トークン）があるので、短くする。
public enum OutputCompactor {
    public static let maxChars = 1800
    /// 画面の文字を読むとき（`snapshot`〔`-i` なし〕・`get`）の上限。操作用より大きい（メッセージの本文を、読めるように）。モデルの入力（約 4000 トークン）に、指示・履歴と一緒に収まる範囲。
    public static let maxReadChars = 2500
    /// 上限を超えるとき、先頭に残す文字数（残りは、末尾。チャットは、新しい発言が下にあるので、末尾を厚く残す）。
    static let readHead = 500

    /// - agent-desktop の `snapshot`：JSON を、「@参照 [役割] 名前」の行にする（操作できる要素だけ。続く `click @参照` に、そのまま使える）。
    /// - agent-desktop の `snapshot`（`-i` なし）：画面の文字（本文・見出し・リンク・入力欄の値）を、上から順に、1 行ずつ。**文字を読むため**で、参照は付かない（操作には、`-i` を使う）。
    /// - agent-desktop の `get`：取った文字そのまま。
    /// - agent-desktop のその他：結果（ok / エラーの種類と文）だけ。
    /// - それ以外：そのまま（長ければ切る）。
    public static func compact(argv: [String], output: String, aliases: RefAliases = RefAliases()) -> String {
        if argv.first == "agent-desktop", let text = readText(argv: argv, output: output) { return keepingEnds(text) }
        let text: String
        if argv.first == "agent-desktop", let compacted = compactAgentDesktop(argv: argv, output: output, aliases: aliases) { text = compacted } else { text = output }
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars)) + "\n…（\(text.count - maxChars) 文字を省略）"
    }

    /// 画面の文字を読む出力（`snapshot`〔`-i` なし〕・`get`）なら、その文字。それ以外・失敗した出力は nil（通常の整形に任せる）。
    static func readText(argv: [String], output: String) -> String? {
        guard let root = jsonObject(in: output), root["ok"] as? Bool == true, let data = root["data"] as? [String: Any] else { return nil }
        if argv.contains("get") { return (data["value"] as? String) ?? "" }
        guard argv.contains("snapshot"), !argv.contains("-i"), !argv.contains("--interactive-only"), let tree = data["tree"] as? [String: Any] else { return nil }
        // 本文の領域：ブラウザなら、ページ（`webarea`）のうち、文字が最も多いもの（メニュー・アドレス欄・ポップアップなど、ブラウザの画面は除く）。ほかのアプリは、ウィンドウ全体
        var pages: [[String: Any]] = []
        func findPages(_ node: [String: Any]) {
            if node["role"] as? String == "webarea" { pages.append(node); return }
            for child in (node["children"] as? [[String: Any]]) ?? [] { findPages(child) }
        }
        findPages(tree)
        var body = pages.map(texts(in:)).max { $0.reduce(0) { $0 + $1.count } < $1.reduce(0) { $0 + $1.count } } ?? texts(in: tree)
        // 上限を超えるときは、先に、雑音（3 文字以下の行＝件数・アイコン・重複）を落とす。本文は、長い行
        if (body.reduce(0) { $0 + $1.count + 1 }) > maxReadChars {
            var seen = Set<String>()
            body = body.filter { $0.count > 3 && seen.insert($0).inserted }
        }
        return (["app: \((data["app"] as? String) ?? "?")"] + (body.isEmpty ? ["(no readable text)"] : body)).joined(separator: "\n")
    }

    /// ノードの下の、画面の文字（上から順。連続する同じ行は、1 つ）。
    static func texts(in node: [String: Any]) -> [String] {
        var lines: [String] = []
        func walk(_ node: [String: Any]) {
            if let role = node["role"] as? String, readableRoles.contains(role) {
                // 入力欄は、値（入れた文字・本文）だけ（空の欄の名前＝見出しは、ここでは要らない）。ほかは、値、なければ名前
                let value = (node["value"] as? String) ?? (role == "textfield" ? nil : node["name"] as? String)
                if let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != lines.last { lines.append(text) }
            }
            for child in (node["children"] as? [[String: Any]]) ?? [] { walk(child) }
        }
        walk(node)
        return lines
    }

    /// agent-desktop の出力の JSON。結果は 1 行の JSON で、前に、警告（stderr。標準出力と混ざる）の行が付くことがある：全体が JSON でなければ、`{` で始まる最後の行を読む。
    static func jsonObject(in output: String) -> [String: Any]? {
        func parse(_ text: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] }   // try?: JSON でなければ、nil（呼び出し側が、元の出力を使う）
        if let whole = parse(output) { return whole }
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("{") }) else { return nil }
        return parse(String(line))
    }

    /// 文字を持つ役割。行や表のセルは、子の文字と重なるので、含めない。
    static let readableRoles: Set<String> = ["statictext", "text", "textarea", "textfield", "heading", "link"]

    /// 上限を超えたら、先頭 `readHead` 文字と、末尾を残す（間は省略と書く）。
    static func keepingEnds(_ text: String) -> String {
        guard text.count > maxReadChars else { return text }
        let omitted = text.count - maxReadChars
        return String(text.prefix(readHead)) + "\n…（\(omitted) 文字を省略）…\n" + String(text.suffix(maxReadChars - readHead))
    }

    static func compactAgentDesktop(argv: [String], output: String, aliases: RefAliases) -> String? {
        // JSON でなければ、整形せずに、そのまま返す（nil → 呼び出し側が元の出力を使う）
        guard let root = jsonObject(in: output) else { return nil }
        guard root["ok"] as? Bool == true else {
            let e = root["error"] as? [String: Any]
            return "error \((e?["code"] as? String) ?? "UNKNOWN"): \((e?["message"] as? String) ?? "")"
        }
        guard argv.contains("snapshot"), let data = root["data"] as? [String: Any], let tree = data["tree"] as? [String: Any] else { return "ok" }
        var lines = ["app: \((data["app"] as? String) ?? "?")"]
        func walk(_ node: [String: Any]) {
            if let ref = node["ref_id"] as? String, let role = node["role"] as? String,
               let actions = node["available_actions"] as? [String], !actions.isEmpty {
                let states = (node["states"] as? [String]) ?? []
                if !states.contains("hidden") && !states.contains("disabled") {
                    let name = (node["name"] as? String) ?? ""
                    lines.append("\(aliases.shorten(ref)) [\(role)] \(name.isEmpty ? "(no name)" : String(name.prefix(40)))\(states.contains("focused") ? " (focused)" : "")")
                }
            }
            for child in (node["children"] as? [[String: Any]]) ?? [] { walk(child) }
        }
        walk(tree)
        return lines.prefix(60).joined(separator: "\n")
    }
}

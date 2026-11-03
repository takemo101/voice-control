import Foundation

/// 言語モデルに返す出力の、整形。モデルの入力には上限（約 4000 トークン）があるので、短くする。
public enum OutputCompactor {
    public static let maxChars = 1800

    /// - agent-desktop の `snapshot`：JSON を、「@参照 [役割] 名前」の行にする（操作できる要素だけ。続く `click @参照` に、そのまま使える）。
    /// - agent-desktop のその他：結果（ok / エラーの種類と文）だけ。
    /// - それ以外：そのまま（長ければ切る）。
    public static func compact(argv: [String], output: String, aliases: RefAliases = RefAliases()) -> String {
        let text: String
        if argv.first == "agent-desktop", let compacted = compactAgentDesktop(argv: argv, output: output, aliases: aliases) { text = compacted } else { text = output }
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars)) + "\n…（\(text.count - maxChars) 文字を省略）"
    }

    static func compactAgentDesktop(argv: [String], output: String, aliases: RefAliases) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
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

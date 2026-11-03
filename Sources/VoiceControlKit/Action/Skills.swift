import Foundation

/// 利用者が JSON で足す、キー操作の定義（スキル）。例：
/// ```json
/// [{ "id": "spotify-next", "label": "Spotify で次の曲へ", "keys": ["cmd+rightarrow"], "app": "Spotify" }]
/// ```
/// - `id`：一意の名前。`label`：Tiny-Jev が読む説明（短く、言い換えを含めてよい）。`keys`：順に押すキー（agent-desktop の `press` の表記）。
/// - `app`（省略可）：前面のアプリの名前に含まれるときだけ候補にする。`when`（省略可）：発話がこの正規表現に一致するときだけ候補にする。`confirm`（省略可）：必ず確認する。
/// 不正な定義は、読み込まずに、理由を返す（黙って無視しない）。アプリを終了するキー（cmd+q 系）は、拒否する。
public struct SkillDefinition: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var keys: [String]
    public var app: String?
    public var when: String?
    public var confirm: Bool?
}

public enum SkillCatalog {
    /// 拒否するキー（agent-desktop も、`--force` なしでは拒否する）。
    public static let forbidden: Set<String> = ["cmd+q", "cmd+shift+q", "cmd+alt+esc", "cmd+option+esc", "ctrl+cmd+q", "cmd+shift+delete"]

    public struct Loaded: Sendable {
        public var shortcuts: [Shortcut] = []
        public var sources: [String: String] = [:]   // id → ファイル名
        public var problems: [String] = []
    }

    /// `directories` の、`*.json`（ファイル名の順）を読む。ないディレクトリは、飛ばす。
    public static func load(directories: [URL]) -> Loaded {
        var result = Loaded()
        let fm = FileManager.default
        for dir in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
                let url = dir.appendingPathComponent(name)
                do {
                    let defs = try JSONDecoder().decode([SkillDefinition].self, from: Data(contentsOf: url))
                    for def in defs {
                        switch validate(def) {
                        case .some(let why): result.problems.append("\(name): \(def.id.isEmpty ? "(id なし)" : def.id)：\(why)")
                        case .none:
                            if let earlier = result.sources[def.id] { result.problems.append("\(name): \(def.id)：id が \(earlier) と重複"); continue }
                            result.sources[def.id] = name
                            result.shortcuts.append(Shortcut(combos: def.keys, option: def.label, confirm: def.confirm ?? false, app: def.app, when: def.when))
                        }
                    }
                } catch {
                    result.problems.append("\(name)：読めない（\(error.localizedDescription)）")
                }
            }
        }
        return result
    }

    /// 不正なら、その理由。
    static func validate(_ def: SkillDefinition) -> String? {
        if def.id.trimmingCharacters(in: .whitespaces).isEmpty { return "id が空" }
        if def.label.trimmingCharacters(in: .whitespaces).isEmpty { return "label が空" }
        if def.keys.isEmpty { return "keys が空" }
        for key in def.keys {
            let normalized = key.lowercased().replacingOccurrences(of: " ", with: "")
            if normalized.isEmpty { return "keys に空の要素" }
            if forbidden.contains(normalized) { return "アプリを終了するキー（\(key)）は使えない" }
        }
        if let when = def.when, (try? NSRegularExpression(pattern: when)) == nil { return "when が正規表現として不正" }
        return nil
    }
}

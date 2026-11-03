import Foundation

/// このツールの置き場所（`~/.voice-control`。環境変数 `VC_HOME` で変える：検証用）。
public enum VoiceControlHome {
    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["VC_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voice-control")
    }
    public static var skillsDirectory: URL { root.appendingPathComponent("skills") }
    public static var settingsFile: URL { root.appendingPathComponent("settings.json") }
}

/// スキル 1 つ：`~/.voice-control/skills/<name>/SKILL.md`。
/// ```
/// ---
/// name: spotify-play
/// description: Spotify で曲を再生・一時停止する
/// allowed-commands:
///   - agent-desktop
///   - open
/// ---
/// （本文：実行を担当する Apple の言語モデルへの指示。英語が確実）
/// ```
public struct Skill: Sendable, Equatable {
    public let name: String
    /// Tiny-Jev が、どのスキルかを選ぶための説明（短く）。
    public let description: String
    /// 実行してよいコマンド（先頭のトークン列。`agent-desktop` ならどの引数でも、`agent-desktop click` なら click だけ）。
    public let allowedCommands: [String]
    /// 実行の前に、必ず確認する。
    public let confirm: Bool
    /// 本文（言語モデルへの指示）。
    public let body: String
    public let file: URL
}

public struct SkillProblem: Sendable, Equatable {
    public let location: String
    public let reason: String
}

public enum SkillStore {
    public static let maxDescription = 200

    public struct Loaded: Sendable {
        public var skills: [Skill] = []
        public var problems: [SkillProblem] = []
    }

    /// `directory/<name>/SKILL.md` を、すべて読む（名前順）。不正なものは、読み込まず、理由を返す。
    public static func load(directory: URL = VoiceControlHome.skillsDirectory) -> Loaded {
        var result = Loaded()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return result }
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let dir = directory.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let file = dir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                result.problems.append(SkillProblem(location: entry, reason: "SKILL.md が読めない"))
                continue
            }
            switch parse(text, directoryName: entry, file: file) {
            case .success(let skill): result.skills.append(skill)
            case .failure(let error): result.problems.append(SkillProblem(location: entry, reason: error.reason))
            }
        }
        return result
    }

    struct ParseError: Error { let reason: String }

    /// SKILL.md の文字列 → `Skill`。
    static func parse(_ text: String, directoryName: String, file: URL) -> Result<Skill, ParseError> {
        guard let (front, body) = splitFrontMatter(text) else { return .failure(ParseError(reason: "先頭に、フロントマター（--- で囲む）がない")) }
        let fields = parseFields(front)
        guard let name = fields["name"]?.scalar, !name.isEmpty else { return .failure(ParseError(reason: "name がない")) }
        guard name.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else { return .failure(ParseError(reason: "name は、英小文字・数字・ハイフン（40 文字まで）")) }
        guard name == directoryName else { return .failure(ParseError(reason: "name（\(name)）が、ディレクトリ名（\(directoryName)）と違う")) }
        guard let description = fields["description"]?.scalar, !description.isEmpty else { return .failure(ParseError(reason: "description がない")) }
        guard description.count <= maxDescription else { return .failure(ParseError(reason: "description が長い（\(description.count) 文字。\(maxDescription) まで）")) }
        // 形：リスト（`- open`）、インライン（`[open, say]`）、1 つだけなら `allowed-commands: open`。
        let field = fields["allowed-commands"]
        let commands = field?.list ?? field?.scalar.map { [$0] } ?? []
        guard !commands.isEmpty else { return .failure(ParseError(reason: "allowed-commands がない（実行してよいコマンドを、明示する）")) }
        for c in commands {
            if let why = CommandPolicy.validateEntry(c) { return .failure(ParseError(reason: "allowed-commands「\(c)」：\(why)")) }
        }
        let confirm = (fields["confirm"]?.scalar).map { ["true", "yes", "on"].contains($0.lowercased()) } ?? false
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(ParseError(reason: "本文（言語モデルへの指示）が空")) }
        return .success(Skill(name: name, description: description, allowedCommands: commands, confirm: confirm, body: trimmed, file: file))
    }

    /// `---` で囲まれた先頭の部分と、残り。
    static func splitFrontMatter(_ text: String) -> (String, String)? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        return (lines[1..<end].joined(separator: "\n"), lines[(end + 1)...].joined(separator: "\n"))
    }

    struct Field { var scalar: String?; var list: [String]? }

    /// 最小の YAML：`key: 値`、`key:` の次の行から `- 項目`、`key: [a, b]`。値の引用符（' "）は外す。
    static func parseFields(_ front: String) -> [String: Field] {
        var fields: [String: Field] = [:]
        var currentList: String?
        func unquote(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) { return String(t.dropFirst().dropLast()) }
            return t
        }
        for raw in front.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty || raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), let key = currentList {
                fields[key]?.list?.append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            guard let colon = raw.firstIndex(of: ":"), !raw.hasPrefix(" ") else { continue }
            let key = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                fields[key] = Field(scalar: nil, list: [])
                currentList = key
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                let items = value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
                fields[key] = Field(scalar: nil, list: items)
                currentList = nil
            } else {
                fields[key] = Field(scalar: unquote(value), list: nil)
                currentList = nil
            }
        }
        return fields
    }
}

/// 設定（`~/.voice-control/settings.json`）。スキルの有効・無効。**既定は有効**（無効にしたものだけ、記録する）。
public struct Settings: Codable, Sendable, Equatable {
    public var disabledSkills: [String] = []

    public static func load(from file: URL = VoiceControlHome.settingsFile) -> Settings {
        guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(to file: URL = VoiceControlHome.settingsFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    public func isEnabled(_ name: String) -> Bool { !disabledSkills.contains(name) }

    public mutating func setEnabled(_ name: String, _ enabled: Bool) {
        disabledSkills.removeAll { $0 == name }
        if !enabled { disabledSkills.append(name); disabledSkills.sort() }
    }
}

import Foundation

/// SKILL.md の読み込み（フロントマターの解析）。
extension SkillStore {
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

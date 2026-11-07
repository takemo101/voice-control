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
        let commands = (field?.list ?? field?.scalar.map { [$0] } ?? []).map { expandSkillDir($0, file: file) }
        guard !commands.isEmpty else { return .failure(ParseError(reason: "allowed-commands がない（実行してよいコマンドを、明示する）")) }
        for c in commands {
            // 許可は、発話で変えられない（`${USER_REQUEST}` は、本文だけ）。知らない記号は、書き間違い
            if c.contains("${\(SkillPlaceholder.userRequest)}") { return .failure(ParseError(reason: "allowed-commands「\(c)」：${USER_REQUEST} は、本文だけに書ける（許可を、発話で変えないため）")) }
            if let unknown = SkillPlaceholder.unknownNames(in: c).first { return .failure(ParseError(reason: "allowed-commands「\(c)」：知らない記号 ${\(unknown)}（使えるのは ${SKILL_DIR}）")) }
            if let why = CommandPolicy.validateEntry(c) { return .failure(ParseError(reason: "allowed-commands「\(c)」：\(why)")) }
        }
        let confirm = (fields["confirm"]?.scalar).map { ["true", "yes", "on"].contains($0.lowercased()) } ?? false
        // 返事の扱い：書かなければ、画面に出すだけ。`markdown-note` なら、Markdown のファイルにして開く。`markdown-window` なら、整形して、ウィンドウに表示する
        var resultMode = Skill.ResultMode.text
        if let text = fields["result"]?.scalar {
            guard let mode = Skill.ResultMode(rawValue: text) else { return .failure(ParseError(reason: "result「\(text)」は使えない（markdown-note・markdown-window）")) }
            resultMode = mode
        }
        // コマンド 1 つの実行時間の上限（秒）。書かなければ、既定（30 秒）。範囲外・数でないものは、書き間違いなので、読み込みの失敗にする
        var commandTimeout = CommandRunner.defaultTimeout
        if let text = fields["timeout"]?.scalar {
            let range = Skill.commandTimeoutRange
            guard let seconds = Int(text), range.contains(seconds) else {
                return .failure(ParseError(reason: "timeout「\(text)」は使えない（\(range.lowerBound)〜\(range.upperBound) の整数。秒）"))
            }
            commandTimeout = TimeInterval(seconds)
        }
        let trimmed = expandSkillDir(body, file: file).trimmingCharacters(in: .whitespacesAndNewlines)
        if let unknown = SkillPlaceholder.unknownNames(in: trimmed).first {
            return .failure(ParseError(reason: "本文に、知らない記号 ${\(unknown)}（使えるのは ${SKILL_DIR}・${USER_REQUEST}。書き間違いでなければ、$ と { の間に、スペースなどを入れる）"))
        }
        guard !trimmed.isEmpty else { return .failure(ParseError(reason: "本文（言語モデルへの指示）が空")) }
        var skill = Skill(name: name, description: description, allowedCommands: commands, confirm: confirm, body: trimmed, file: file)
        skill.result = resultMode
        skill.external = (fields["external"]?.scalar).flatMap { $0.isEmpty ? nil : $0 }
        skill.commandTimeout = commandTimeout
        skill.acceptsPrevious = (fields["accepts-previous"]?.scalar).map { ["true", "yes", "on"].contains($0.lowercased()) } ?? false
        return .success(skill)
    }

    /// スキルのディレクトリを表す、`allowed-commands` と本文の中の記号。
    static let skillDirPlaceholder = "${SKILL_DIR}"

    /// `${SKILL_DIR}` を、そのスキルのディレクトリ（SKILL.md のある場所。絶対パス）に置き換える。
    /// スクリプトを同梱するスキルが、置かれた場所（グローバルでも、プロジェクトでも）に関わらず、同じ SKILL.md で動く（個人のパスを、書かずに済む）。
    /// 空白・引用符・`\` を含むパスは、`CommandPolicy.tokenize` が 1 つに読めるよう、`"…"` で囲む。置き換えるのは、ファイルシステムの場所だけ（言語モデルの出力ではない）。
    static func expandSkillDir(_ text: String, file: URL) -> String {
        guard text.contains(skillDirPlaceholder) else { return text }
        let path = file.deletingLastPathComponent().path
        let plain = path.range(of: #"[\s'"\\]"#, options: .regularExpression) == nil
        let value = plain ? path : "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return text.replacingOccurrences(of: skillDirPlaceholder, with: value)
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

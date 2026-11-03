import Foundation
@testable import VCSkill

/// 説明だけが違う、テスト用のスキル（`open` だけを許可する）。`Skill` の初期化子は `VCSkill` の中だけなので、`@testable` が要る。
func skill(_ name: String, _ description: String, confirm: Bool = false) -> Skill {
    Skill(name: name, description: description, allowedCommands: ["open"], confirm: confirm, body: "x", file: URL(fileURLWithPath: "/tmp/\(name)/SKILL.md"))
}

/// SKILL.md の文章を読む（ディレクトリ名は `dir`）。
func parse(_ text: String, dir: String = "demo") -> Result<Skill, SkillStore.ParseError> {
    SkillStore.parse(text, directoryName: dir, file: URL(fileURLWithPath: "/tmp/SKILL.md"))
}

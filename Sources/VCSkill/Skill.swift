import Foundation

/// スキル 1 つ：`~/.voice-control/skills/<name>/SKILL.md`（グローバル）か `<プロジェクトのルート>/.voice-control/skills/<name>/SKILL.md`（プロジェクト）。
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
    /// どこに置かれているか。
    public var scope: Scope = .global
    /// 言語モデルの最後の返事（Markdown）を、一時ディレクトリのファイルに保存して、開く（フロントマター `result: markdown-note`）。
    public var opensResultAsNote = false

    public enum Scope: String, Sendable { case global, project, builtin }
}

public struct SkillProblem: Sendable, Equatable {
    public let location: String
    public let reason: String
}

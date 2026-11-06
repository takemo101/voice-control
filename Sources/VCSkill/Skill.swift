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
    /// 最後の返事の扱い（フロントマター `result`）。
    public var result: ResultMode = .text
    /// 1 つのコマンドの、実行時間の上限（秒。フロントマター `timeout`）。書かなければ、`CommandRunner.defaultTimeout`（30 秒）。
    public var commandTimeout: TimeInterval = CommandRunner.defaultTimeout
    /// `timeout` に書ける範囲（秒）。上限は、止まらないコマンドが、いつまでも残らないための歯止め（Esc の取りやめは、いつでも効く）。
    public static let commandTimeoutRange: ClosedRange<Int> = 1...600

    public enum ResultMode: String, Sendable {
        /// 画面に出すだけ（既定）。
        case text
        /// 最後の返事（Markdown）を、一時ディレクトリのファイルに保存して、開く（`markdown-note`）。
        case markdownNote = "markdown-note"
        /// 最後の返事（Markdown）を、整形して、一時的なウィンドウに表示する（`markdown-window`。コピーもできる）。
        case markdownWindow = "markdown-window"

        /// 返事が、Markdown の本文だけ（`done:` を付けない）になる。
        var repliesWithDocument: Bool { self != .text }
    }

    public enum Scope: String, Sendable { case global, project, builtin }
}

public struct SkillProblem: Sendable, Equatable {
    public let location: String
    public let reason: String
}

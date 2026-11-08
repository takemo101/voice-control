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
    /// このスキルが、利用者の発話を、**この Mac の外へ送る**とき、その送り先（フロントマター `external`。例：`Google（agy）`）。書かなければ、送らない。
    /// 一覧・インストールの結果に出し、`--all` のインストールのあとに、注意を出す（`vc` の基本：発話を、この Mac の外へ出さない、の例外を、見えるようにする）。
    public var external: String?
    /// **撮ったスクリーンショットを使うスキル**（フロントマター `image: true`）。いまのスクリーンショットがあるときだけ、Tiny-Jev の選択肢に入る（コードが決める：撮っていない・古いときは、選ばれない）。
    /// 画像を使わない依頼が、画像のスキルに振り分けられない（画像を、外へ送るスキルと、取り違えない）。
    public var image = false

    /// 撮った画面の画像を、外へ送るスキルか（`image: true` と `external`）。確認のとき、送る画像を見せる。
    public var sendsScreenshot: Bool { image && external != nil }

    /// 外へ送ることの、断り書き（「撮った画面の画像と質問を、OpenAI（codex） へ送ります」）。送らなければ nil。確認の文・一覧・インストールの結果で使う。
    public var externalNotice: String? { external.map { "\(sendsScreenshot ? "撮った画面の画像と質問" : "発話")を、\($0) へ送ります" } }
    /// 複数ステップの依頼で、**前のステップの結果**（返事）を、受け取ってよいか（フロントマター `accepts-previous`。既定は false）。
    /// 結果は、信頼しないデータ（`PreviousResult`）。外の内容を含みうるので、受け取る（宣言する）スキルは、そのデータで、危ない動作をしないものだけ。
    public var acceptsPrevious: Bool = false
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

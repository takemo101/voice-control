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
    /// 外へ送ることの、断り書き（「発話を、Google（agy） へ送ります」）。送らなければ nil。一覧・インストールの結果で使う。
    public var externalNotice: String? { external.map { "発話を、\($0) へ送ります" } }
    /// **依頼の文が、この正規表現に合うときだけ、確認する**（フロントマター `confirm-when`）。`confirm: true`（いつも確認）と違い、**コードが、依頼の文から決める**。
    /// 外へ送る量が増える依頼（撮った画面の画像を、外のエージェントへ送る）だけ、確認したいスキルが使う。確認を通った実行だけが、環境変数 `VC_CONFIRMED=1` を受ける（スクリプトが、確かめる：確認なしに、送らないため）。
    public var confirmWhen: String?
    /// `confirm-when` に合ったとき、確認の文に書く、外へ送るもの（フロントマター `confirm-sends`。例：「撮った画面の画像と質問」）。
    public var confirmSends = "発話"

    /// この依頼は、実行の前に、確認が要るか。
    public func needsConfirmation(for request: String) -> Bool {
        if confirm { return true }
        guard let confirmWhen, let regex = try? NSRegularExpression(pattern: confirmWhen) else { return false }   // try?: 書き方は、読み込みで、検査済み
        return regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)) != nil
    }

    /// 確認の理由：外へ送るスキルは、**何を、どこへ送るか**を言う（確認で、何に「はい」と言うのかが、分かるように）。
    public func confirmReason(for request: String) -> String {
        guard let external else { return SkillResolver.confirmRequiredReason }
        let sent = (confirmWhen != nil && !confirm) ? confirmSends : "発話"
        return "\(sent)を、\(external) へ送ります。実行の前に確認します"
    }
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

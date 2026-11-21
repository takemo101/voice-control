import Foundation

/// 利用者への確認（道具が、上書き・安全でないコマンドの前に聞く）。実行してよければ true。`detail`：何をするか（画面に出す）。
public typealias ToolConfirm = @Sendable (_ detail: String) async -> Bool

/// 1 回の質問に付く、任意のもの。
public struct ChatCallOptions: Sendable {
    /// いまの操作（実行したコマンド・検索など）を、知らせる。
    public var onActivity: ActivityHandler?
    /// **答えの文字が、届くたびに**（常駐の接続〔ACP〕の、エージェントだけ。少しずつ届く）。届いた順に、続きの文字だけを渡す。最終的な答え（`respond` の戻り値）が、正：これは、表示・読み上げを、早く始めるためのもの。
    public var onText: (@Sendable (String) -> Void)?
    /// 確認が要る操作の前に、利用者に聞く（なければ、確認が要る操作は、しない：Apple の会話の道具と、ACP の許可の確認が使う）。
    public var confirm: ToolConfirm?
    /// 外のエージェントに見せる画像（**利用者が、送ることを確かめたもの**。作業フォルダへ、一時的にコピーして渡し、終わったら消す）。
    public var image: URL?
    /// Web の道具（検索・ページの取得）を使ってよいか（Apple の会話だけ）。**画像・コピーした文章が、会話に入っているとき**は、使わない：画面の内容が、モデルの作る検索語に混ざって、外へ出ないように。
    public var allowsWeb = true
    /// この質問に、最新の情報（Web）が要るか（Tiny-Jev の判定。Apple の会話だけ）。言葉の一致で拾えない言い方を、補う。
    public var needsWeb: (@Sendable (String) -> Bool)?
    /// 自動モードで、コードの規則が決められないコマンドが、無害か（Tiny-Jev。ACP の会話だけ）。
    public var judgeCommand: CommandJudge?
    /// この呼び出しは、会話の往復ではない（要約など）：常駐の接続（ACP）では、会話のセッションの記憶に、数えない（次の質問は、新しいセッションで、過去の往復を渡す）。
    public var standalone: Bool

    public init(onActivity: ActivityHandler? = nil, onText: (@Sendable (String) -> Void)? = nil, confirm: ToolConfirm? = nil, image: URL? = nil, allowsWeb: Bool = true, needsWeb: (@Sendable (String) -> Bool)? = nil, judgeCommand: CommandJudge? = nil, standalone: Bool = false) {
        self.onActivity = onActivity; self.onText = onText; self.confirm = confirm; self.image = image; self.allowsWeb = allowsWeb; self.needsWeb = needsWeb; self.judgeCommand = judgeCommand; self.standalone = standalone
    }
}

/// 実行中の様子と、質問ごとの付け足し（`ChatCallOptions`）を受ける答える側（外のエージェント・Apple のモデル）。
public protocol ActivityReporting: ChatBackend {
    func respond(instructions: String, turns: [ChatTurn], user: String, options: ChatCallOptions) async throws -> String
}

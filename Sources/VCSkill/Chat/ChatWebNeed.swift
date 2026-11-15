import Foundation
import VCDecision

/// 会話（Apple のモデル＋道具）で、**最新の情報（Web の道具）が要る質問か**の判定。
/// 言葉の一致（「調べて」「検索」「最新」「天気」「株価」）は、「今日の阪神の試合は？」「ドルは、いま何円？」のような言い方を見落とし、道具を呼ばない作り話が、そのまま返った。
/// **Tiny-Jev が、質問の種類を、多択で選ぶ**（最新の情報を 1 つ、ほかの種類〔知識・あいさつ・提案・続きの質問〕を並べる）。
///
/// **測定（`vc eval-judge web`。docs/verification.md）**：18+18 文（`chat-web.tsv`。言い方の選択に使った）：最新の情報が要る 13/18 を拾い、要らない 18/18 を、誤らなかった（言葉の一致は、6/18・18/18）。
/// 見ずに作った 30 文（`chat-web-test.tsv`）：8/14 を拾い、要らない 16/16 を、誤らなかった。2 択の言い方は、確率が偏って、使えなかった。
/// **判定が「要る」でも、言葉の一致のように、失敗にはしない**（`ToolUseGuard.judgedWeb`）：道具を使うよう 1 度促し、それでも呼ばれなければ、そのまま答えを返す。
public struct ChatWebNeed: Sendable {
    /// 最新の情報についての確率の下限（上の測定で決めた）。
    public static let threshold = 0.6
    private let scorer: OptionScorer
    public init(scorer: OptionScorer) { self.scorer = scorer }

    public func probability(request: String) throws -> Double {
        try scorer.score(
            state: "発話: \(request)", question: "この発話は、何についてか",
            options: ["今日・いま・最新の情報（天気・ニュース・株価・試合の結果・ランキング・為替）についての質問", "一般的な知識・仕組み・使い方の質問",
                      "あいさつ・お礼・雑談", "文章・アイデア・提案を作る依頼", "続きの質問（それ・さっきの・もう少し）"])[0]
    }

    public func needsWeb(_ request: String) -> Bool {
        ((try? probability(request: request)) ?? 0) >= Self.threshold   // 判定できなければ、「要らない」（言葉の一致は、別に効く）
    }
}

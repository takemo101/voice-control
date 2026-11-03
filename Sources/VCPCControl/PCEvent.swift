import Foundation
import VCDecision

/// PC 操作の流れの経過（`PCRunner` が、起きた順に、`PCReporter` へ送る）。表示・読み上げ・画面の上の表示は、受け取る側が決める。
public enum PCEvent: Sendable {
    /// 言語モデルで、発話を分けた（`--llm-split`）。
    case llmSplit([String])
    /// 言語モデルで分けられなかった（ルールで分ける）。
    case llmSplitFailed(String)
    /// 1 手の処理を始める。`index` は 1 から。
    case clause(index: Int, count: Int, text: String)
    /// 計画ができた。
    case planned(Plan)
    /// 実行しない判定（`Plan.step` が `nil`、または `.reject`）。`cancelsRemaining`：残りの手があり、それも中止する。
    case rejected(Plan, cancelsRemaining: Bool)
    /// 計画の表示だけで、実行しない（plan）。
    case planOnly(Step)
    /// 実行しない（`--execute` なし）。
    case dryRun(Step)
    /// 確認が要る。このあと、`confirm` を呼ぶ。
    case confirmRequired(Step)
    /// 確認の返事を受けた（承認でも、承認でなくても）。
    case confirmAnswered(approved: Bool)
    /// 確認で承認されなかった（実行しない）。`cancelsRemaining`：残りの手があり、それも中止する。
    case notConfirmed(Step, cancelsRemaining: Bool)
    /// 実行を始める。
    case executing(Step)
    /// 実行した（履歴に積んだあと）。
    case executed(Step)
}

/// `PCEvent` の受け手（端末・画面の上の表示など）。
public protocol PCReporter {
    func report(_ event: PCEvent)
}

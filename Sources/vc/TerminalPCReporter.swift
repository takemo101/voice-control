import Foundation
import VCPCControl

/// PC 操作の流れの出来事（`PCEvent`）を、端末へ出す（`vc plan`・`vc act`。声の流れの `HUDPCReporter` も、端末の分は、これを使う）。
struct TerminalPCReporter: PCReporter {
    /// 出力先（既定は、標準出力。テストで差し替える）。
    var out: @Sendable (String) -> Void = { print($0) }

    func report(_ event: PCEvent) {
        switch event {
        case let .llmSplit(steps):
            out("言語モデルで分けた：" + steps.joined(separator: " ／ "))
        case let .llmSplitFailed(message):
            out("言語モデルで分けられない（\(message)）。ルールで分ける")
        case let .clause(index, count, text):
            out(headingText(count > 1 ? "[\(index)/\(count)] \(text)" : text))
        case let .planned(plan):
            for line in Self.describe(plan) { out(line) }
        case let .rejected(_, cancelsRemaining):
            out("  " + Style.dim("→ 実行しない" + (cancelsRemaining ? "（残りも中止）" : "")))
        case .planOnly:
            break
        case .dryRun:
            out("  " + Style.dim("dry-run：実行していない（--execute で実行）"))
        case .confirmRequired, .confirmAnswered, .executing:
            break   // 端末では、確認は --yes（問い合わせない）。表示するのは、結果だけ
        case let .notConfirmed(_, cancelsRemaining):
            out("  " + Style.yellow("やめた（確認が取れない）" + (cancelsRemaining ? "。残りも中止" : "")))
        case .executed:
            out("  " + Style.green("✓ done"))
        }
    }

    /// 計画の表示（選択・危険度・手・判定・注意）。
    static func describe(_ plan: Plan) -> [String] {
        var lines = [kvText("選択", "\(plan.choice)  \(pct(plan.probability))" + Style.dim("（採点 \(plan.rounds) 回）"))]
        if let risk = plan.risk { lines.append(kvText("危険度", pct(risk) + Style.dim("（取り消しにくい確率）"))) }
        if let step = plan.step { lines.append(kvText("手", step.summary)) }
        let verdict: String
        switch plan.verdict {
        case .execute: verdict = Style.green("✓ 実行")
        case .confirm: verdict = Style.yellow("? 確認が要る")
        case .reject: verdict = Style.red("✗ 実行しない")
        }
        lines.append(kvText("判定", verdict + (plan.rejection.map { Style.dim("（\($0)）") } ?? "")))
        if let note = plan.note { lines.append(noticeText(note)) }
        return lines
    }
}

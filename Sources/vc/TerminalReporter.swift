import Foundation
import VCSkill

/// スキルの実行の出来事（`RunEvent`）を、端末へ出す。
/// 表示の組み立ては 2 つ：`.command`（`vc run` と、Enter で録音する `vc listen`。見出しつき。失敗は標準エラーへ）と、声の流れ（見出しなし。確認は声で。失敗は標準出力へ。`HUDReporter` が、これを使う）。
struct TerminalReporter: RunReporter {
    enum Layout: Sendable {
        case command
        case voice
    }

    let layout: Layout
    let dryRun: Bool
    /// 出力先（既定は、標準出力・標準エラー。テストで差し替える）。
    var out: @Sendable (String) -> Void = { print($0) }
    var err: @Sendable (String) -> Void = { eprint($0) }

    func report(_ event: RunEvent) {
        switch event {
        case let .forced(skill):
            out(kvText("指定", Style.bold(skill.name)))
            describe(skill)
        case let .matched(skill, probability, elapsed):
            out(kvText("Tiny-Jev", Style.bold(skill.name) + "  \(pct(probability))" + Style.dim("（\(seconds(elapsed: elapsed))）")))
            describe(skill)
        case let .fellBack(skill, probability, risk, elapsed):
            out(kvText("Tiny-Jev", Style.dim("どのスキルでもない") + " → 既定スキル " + Style.bold(skill.name)
                       + Style.dim("（操作の依頼 \(pct(probability))・取り消しにくさ \(pct(risk))・\(seconds(elapsed: elapsed))）")))
            describe(skill)
        case let .declined(reason, _, elapsed):
            out(kvText("Tiny-Jev", Style.dim("（どのスキルでもない）") + Style.dim("（\(seconds(elapsed: elapsed))）")))
            switch layout {
            case .command: out("\n  " + Style.dim("→ 実行しない（\(reason)）"))
            case .voice: out("  " + Style.dim("→ 実行しない（\(reason)）"))
            }
        case let .confirmRequired(_, reason):
            switch layout {
            case .command: out(noticeText(reason + "。"))
            case .voice: out(noticeText("確認待ち：もう一度トリガーを押して「はい」と言う（\(reason)）"))
            }
        case .confirmationDeclined:
            out("  " + Style.dim("やめた"))
        case .confirmed:
            break
        case .started:
            if layout == .command { out(headingText(dryRun ? "実行（dry-run：コマンドは実行しない）" : "実行")) }
        case let .command(command):
            out("  " + Style.bold("$ " + command))
        case let .result(code, output):
            out("    " + (code == 0 ? Style.green("✓ exit 0") : Style.red("✗ exit \(code)")))
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.prefix(8) { out("    " + Style.dim("│ ") + line) }
            if lines.count > 8 { out("    " + Style.dim("… 他 \(lines.count - 8) 行")) }
        case let .denied(command, reason):
            out("  " + Style.red("✗ 拒否: ") + command + Style.dim("  — " + reason))
        case let .reply(reply, commandCount, elapsed):
            if layout == .command { out(headingText("結果")) }
            out(kvText("返事", reply))
            out(kvText("所要", seconds(elapsed: elapsed) + "・実行したコマンド \(commandCount) 件" + (dryRun ? Style.dim("（dry-run）") : "")))
        case let .failed(message):
            switch layout {
            case .command: err(Style.errRed("エラー:") + " " + message)
            case .voice: out(Style.red("失敗:") + " \(message)")
            }
        case .cancelled:
            out("  " + Style.yellow("取りやめました（Esc）"))
        }
    }

    /// 選んだスキルの説明と許可。説明は、`vc run` だけが出す。
    private func describe(_ skill: Skill) {
        if layout == .command { out(kvText("説明", skill.description)) }
        out(kvText("許可", skill.allowedCommands.joined(separator: "、")))
    }
}

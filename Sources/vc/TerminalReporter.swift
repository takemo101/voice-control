import VCCore
import Foundation
import VCSkill

/// スキルの実行の出来事（`RunEvent`）を、端末へ出す。
/// 表示の組み立ては 2 つ：`.command`（`vc run` と、Enter で録音する 声の入力。見出しつき。失敗は標準エラーへ）と、声の流れ（見出しなし。確認は声で。失敗は標準出力へ。`HUDReporter` が、これを使う）。
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
    /// 結果（Markdown の答え・加工した画像）の見せ先（既定は、別のプロセスのウィンドウ・パネル）。
    var presenters = ResultPresenters.live

    func report(_ event: RunEvent) {
        switch event {
        case let .forced(skill):
            out(kvText(tr("指定"), Style.bold(skill.name)))
            describe(skill)
        case let .matched(skill, probability, elapsed):
            out(kvText("Tiny-Jev", Style.bold(skill.name) + "  \(pct(probability))" + Style.dim(tr("（\(seconds(elapsed: elapsed))）"))))
            describe(skill)
        case let .fellBack(skill, probability, risk, elapsed):
            out(kvText("Tiny-Jev", Style.dim(tr("どのスキルでもない")) + " → " + tr("既定スキル ") + Style.bold(skill.name)
                       + Style.dim(tr("（操作の依頼 \(pct(probability))・取り消しにくさ \(pct(risk))・\(seconds(elapsed: elapsed))）"))))
            describe(skill)
        case let .declined(reason, _, elapsed):
            out(kvText("Tiny-Jev", Style.dim(tr("（どのスキルでもない）")) + Style.dim(tr("（\(seconds(elapsed: elapsed))）"))))
            switch layout {
            case .command: out("\n  " + Style.dim(tr("→ 実行しない（\(reason)）")))
            case .voice: out("  " + Style.dim(tr("→ 実行しない（\(reason)）")))
            }
        case let .confirmRequired(skill, reason):
            if layout == .command { ConfirmImagePanel.show(for: skill) }   // 声の流れは、画面の上のパネルに、画像が出る（`HUDImage`）
            switch layout {
            case .command: out(noticeText(tr("\(reason)。")))
            case .voice: out(noticeText(tr("確認待ち：パネルの\(ConfirmGuide.howToAnswer)（\(reason)）")))
            }
        case .confirmationDeclined:
            ConfirmImagePanel.dismiss()
            out("  " + Style.dim(tr("やめた")))
        case .confirmed:
            ConfirmImagePanel.dismiss()
        case .started:
            if layout == .command { out(headingText(dryRun ? tr("実行（dry-run：コマンドは実行しない）") : tr("実行"))) }
        case let .command(command):
            out("  " + Style.bold("$ " + command))
        case let .result(code, output):
            out("    " + (code == 0 ? Style.green("✓ exit 0") : Style.red("✗ exit \(code)")))
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.prefix(8) { out("    " + Style.dim("│ ") + line) }
            if lines.count > 8 { out("    " + Style.dim(tr("… 他 \(lines.count - 8) 行"))) }
        case let .denied(command, reason):
            out("  " + Style.red(tr("✗ 拒否: ")) + command + Style.dim("  — " + reason))
        case let .document(markdown):
            if let why = presenters.document(markdown) { err(Style.red(tr("ウィンドウを出せません: ")) + why) }
        case let .image(url):
            if let why = presenters.image(url) { err(Style.red(tr("パネルを出せません: ")) + why) }
        case let .reply(reply, commandCount, elapsed):
            if layout == .command { out(headingText(tr("結果"))) }
            out(kvText(tr("返事"), reply))
            out(kvText(tr("所要"), seconds(elapsed: elapsed) + tr("・実行したコマンド \(commandCount) 件") + (dryRun ? Style.dim(tr("（dry-run）")) : "")))
        case let .failed(message):
            switch layout {
            case .command: err(Style.errRed(tr("エラー:")) + " " + message)
            case .voice: out(Style.red(tr("失敗:")) + " \(message)")
            }
        case .cancelled:
            out("  " + Style.yellow(tr("取りやめました（Esc）")))
        case let .planned(steps):
            out(kvText(tr("手順"), tr("\(steps.count) つに分けました")))
            for (offset, step) in steps.enumerated() { out("    \(offset + 1). \(step)") }
        case let .stepStarted(index, total, text):
            switch layout {
            case .command: out(headingText(tr("ステップ \(index)/\(total)：\(text)")))
            case .voice: out("\n  " + Style.bold(tr("▶ ステップ \(index)/\(total)")) + tr("：") + text)
            }
        case let .carriedResult(characters):
            out("  " + Style.dim(tr("前のステップの結果を渡しました（\(characters) 文字）")))
        case let .planStopped(completed, total):
            out("  " + Style.yellow(tr("ステップ \(completed + 1)/\(total) で止まりました（済み：\(completed)。残りは実行しません）")))
        }
    }

    /// 選んだスキルの説明と許可。説明は、`vc run` だけが出す。
    private func describe(_ skill: Skill) {
        if layout == .command { out(kvText(tr("説明"), skill.description)) }
        out(kvText(tr("許可"), listJoin(skill.allowedCommands)))
    }
}

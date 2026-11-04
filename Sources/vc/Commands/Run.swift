import Foundation
import VCCore
import VCSkill

struct RunCommand: Command {
    static let info = CommandInfo(
        name: "run", group: .skills, summary: "スキルを選んで、コマンドを実行する",
        usage: ["vc run <依頼> [--skill <name>] [--dry-run] [--yes]"],
        details: [
            "Tiny-Jev が、有効なスキルから、呼ぶものを選ぶ。スキルの本文と依頼文を Apple の言語モデルに渡し、コマンドを実行させる。",
            "実行してよいのは、スキルの allowed-commands に一致するコマンドだけ（シェルは使わない）。実行するコマンドと結果は、すべて表示する。",
            "確信度が 0.70 未満、またはスキルが confirm: true のときは、実行の前に [y/N] で確認する。",
        ],
        options: [
            ("--skill <name>", "Tiny-Jev で選ばず、このスキルを使う（無効なスキルは使えない）"),
            ("--dry-run", "コマンドを実行せず、実行しようとするコマンドだけを表示する（モデルは出力を見られないので、途中は推測になる）"),
            ("--yes", "確認を省略する"),
        ],
        examples: ["vc run \"Safariを開いて\" --dry-run", "vc run \"設定ボタンを押して\" --skill fixture-press --yes"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc run "<依頼>" [--skill <name>] [--dry-run] [--yes]
        // Tiny-Jev が、有効なスキルから、呼ぶものを選び、スキルの本文と依頼文を Apple の言語モデルに渡して、コマンドを実行させる（流れは `SkillRunner`、表示は `TerminalReporter`）。
        // 実行するコマンドと結果は、すべて表示する。実行してよいコマンドは、スキルの allowed-commands だけ（シェルは使わない）。
        var arguments = arguments
        let dryRun = arguments.flag("--dry-run")
        let forced = arguments.option("--skill")
        guard let request = arguments.positionals.first else { usageError("run", "依頼を渡してください（例: vc run \"Safariを開いて\"）") }
        requireAppleIntelligence()
        let skills = context.loadSkills()
        skills.reportProblems()
        let enabled = skills.enabled
        guard !enabled.isEmpty else { fail("有効なスキルがありません（vc skills で確認）") }

        // 見出しは、モデルの読み込みや、指定したスキルの検査より前に出す
        heading("スキルの選択")
        let selection: SkillRunner.Selection
        if let forced {
            guard let skill = skills.loaded.skills.first(where: { $0.name == forced }) else { fail("スキルがありません: \(forced)（一覧：vc skills）") }
            guard skills.settings.isEnabled(skill.name) else { fail("スキル \(forced) は無効です（vc skills enable \(forced)）") }
            selection = .forced(skill)
        } else {
            selection = .resolve(skills: enabled, scorer: context.loadJev(), gate: context.gate)
        }

        let yes = context.options.yes
        let outcome: RunOutcome
        do {
            outcome = try await SkillRunner(selection: selection, dryRun: dryRun).run(request, reporter: TerminalReporter(layout: .command, dryRun: dryRun), confirm: { askOnTerminal(yes: yes) })
        } catch { fail("\(error)") }
        // 失敗は、`TerminalReporter` が、標準エラーへ出している。ここでは、終了コードだけ
        switch outcome {
        case .failed, .cancelled: exit(1)
        case .completed, .declined, .notConfirmed: break
        }
    }
}

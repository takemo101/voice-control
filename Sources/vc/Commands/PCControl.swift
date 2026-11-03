import Foundation
import VCPCControl
import VCSpeech

struct PlanCommand: Command {
    static let info = CommandInfo(
        name: "plan", group: .pcControl, summary: "発話から選んだ操作・確率・判定を表示する（実行しない）",
        usage: ["vc plan <発話> [--app <名前>]", "vc plan --audio <ファイル> [--app <名前>]"],
        details: [
            "前面のアプリの画面・アプリ・ショートカット・スクロールなどの候補から、Tiny-Jev が 1 手を選ぶ。複数の手に分けて、それぞれ表示する。",
            "--app を付けなければ、そのとき前面にあるアプリが対象（端末から実行すると、端末自身）。",
        ],
        options: [
            ("--app <名前>", "対象のアプリ"),
            ("--audio <ファイル>", "音声ファイルから文字起こしして、発話にする"),
            ("--llm-split", "Apple の言語モデルで、発話を 1 手ずつに書き直す（既定はルール）"),
            ("--no-context", "前の指示を、文脈に使わない"),
            ("--no-location", "要素の位置情報を、選択肢に添えない"),
            ("--keys <dir>", "キー操作の JSON 定義のディレクトリ"),
        ],
        examples: ["vc plan \"下にスクロールして\"", "vc plan --app Fixture \"削除して\""])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        try await planOrAct("plan", arguments, context)
    }
}

struct ActCommand: Command {
    static let info = CommandInfo(
        name: "act", group: .pcControl, summary: "発話から選んだ操作を実行する",
        usage: ["vc act <発話> [--app <名前>] [--execute] [--yes]", "vc act --audio <ファイル> [--execute] [--yes]"],
        details: [
            "plan と同じ流れ。既定は dry-run（--execute を付けたときだけ、実際に操作する）。",
            "確認が要る判定は、--yes がなければ実行しない。",
        ],
        options: [
            ("--execute", "実際に操作する"),
            ("--yes", "確認が要る判定を、承認する"),
            ("--app <名前> / --audio <ファイル> / --llm-split / --no-context / --no-location / --keys <dir>", "plan と同じ"),
        ],
        examples: ["vc act --app Fixture \"設定を開いて\" --execute"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        try await planOrAct("act", arguments, context)
    }
}

/// `vc plan`・`vc act`：同じ流れ（`act` は、`--execute` で実行する）。流れは `PCRunner`、表示は `TerminalPCReporter`。
@MainActor private func planOrAct(_ command: String, _ arguments: Arguments, _ context: CommandContext) async throws {
    guard arguments.positionals.count >= 1 || context.options.audio != nil else { usageError(command, "発話か --audio <ファイル> を渡してください（例: vc \(command) \"下にスクロールして\"）") }
    let desktop = AgentDesktop(app: context.options.app)
    let planner = Planner(scorer: context.loadJev(), desktop: desktop, gate: context.gate, skills: context.skillCatalog.shortcuts, useLocation: !context.options.noLocation)
    let mode: PCRunner.Mode = command == "act" ? (context.options.execute ? .execute : .dryRun) : .plan
    let runner = PCRunner(planner: planner, desktop: desktop, mode: mode, usesHistory: !context.options.noContext, llmSplit: context.options.llmSplit)
    do {
        var utterance = arguments.positionals.first ?? ""
        if let audio = context.options.audio {
            utterance = try await FileTranscriber().transcribe(file: URL(fileURLWithPath: audio))
            kv("聞こえた", utterance)   // 文字起こしの表示は、この検証の端末だけ（ファイルには残さない）
        }
        try await runner.run(utterance, reporter: TerminalPCReporter(), confirm: { context.options.yes })
    } catch { fail("\(error)") }
}

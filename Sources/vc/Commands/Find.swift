import Foundation
import VCSkill

struct FindCommand: Command {
    static let info = CommandInfo(
        name: "find", group: .skills, summary: "ファイルを探す（Spotlight。読み取りだけ）",
        usage: ["vc find [--name <文字>] [--in <フォルダ>] [--ext <拡張子>] [--since <7d|2w|1m|12h>] [--limit <件数>] [--oldest]"],
        details: [
            "名前・場所・種類・期間で、候補を集める。Spotlight（`mdfind`）で速く探し、見つからなければ（できたばかりのファイルなど）、フォルダをたどって探す（4 秒・20 万件まで）。隠しフォルダ・Library・キャッシュ・アプリの中・node_modules は、除く。",
            "並びは、名前の一致（そのまま・前方・含む）→ 新しさ（--oldest なら古さ）。開く・動かす・消すは、しない。",
            "スキルの中では、`allowed-commands` に `vc find` と `vc pick` を書くと、言語モデルが呼べる（Tiny-Jev が、依頼に合うものを選ぶ）。例：`.voice-control/skills/file-search`。",
            "ファイル名・パスは、画面にだけ出す（ファイル・ログに残さない）。",
        ],
        options: [("--name <文字>", "名前に含まれる文字（空白区切りは、すべてを含む）"), ("--in <フォルダ>", "探す場所（既定：ホーム）"), ("--ext <拡張子>", "拡張子（pdf など）"), ("--since <期間>", "更新が新しいもの（7d・2w・1m・12h）"), ("--limit <件数>", "候補の最大数（既定 30）"), ("--oldest", "古いものを先にする")],
        examples: ["vc find --name 請求書 --in ~/Documents --ext pdf --since 30d"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let result = ToolCommands.find(Array(arguments.remaining.dropFirst()))
        if result.exitCode == 0 { print(result.output) } else { fail(result.output.replacingOccurrences(of: "error: ", with: "")) }
    }
}

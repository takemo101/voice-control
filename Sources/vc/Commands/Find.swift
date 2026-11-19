import Foundation
import VCCore
import VCSkill

struct FindCommand: Command {
    static let info = CommandInfo(
        name: "find", group: .skills, summary: tr("ファイルを探す（Spotlight。読み取りだけ）"),
        usage: [tr("vc find [--name <文字>] [--in <フォルダ>] [--ext <拡張子>] [--since <7d|2w|1m|12h>] [--limit <件数>] [--oldest]")],
        details: [
            tr("名前・場所・種類・期間で、候補を集める。Spotlight（`mdfind`）で速く探し、見つからなければ（できたばかりのファイルなど）、フォルダをたどって探す（4 秒・20 万件まで）。隠しフォルダ・Library・キャッシュ・アプリの中・node_modules は、除く。"),
            tr("並びは、名前の一致（そのまま・前方・含む）→ 新しさ（--oldest なら古さ）。開く・動かす・消すは、しない。"),
            tr("スキルの中では、`allowed-commands` に `vc find` と `vc pick` を書くと、言語モデルが呼べる（Tiny-Jev が、依頼に合うものを選ぶ）。例：`.voice-control/skills/file-search`。"),
            tr("ファイル名・パスは、画面にだけ出す（ファイル・ログに残さない）。"),
        ],
        options: [(tr("--name <文字>"), tr("名前に含まれる文字（空白区切りは、すべてを含む）")), (tr("--in <フォルダ>"), tr("探す場所（既定：ホーム）")), (tr("--ext <拡張子>"), tr("拡張子（pdf など）")), (tr("--since <期間>"), tr("更新が新しいもの（7d・2w・1m・12h）")), (tr("--limit <件数>"), tr("候補の最大数（既定 30）")), ("--oldest", tr("古いものを先にする"))],
        examples: ["vc find --name 請求書 --in ~/Documents --ext pdf --since 30d"])   // l10n-skip: 入力例のコマンド

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let result = ToolCommands.find(Array(arguments.remaining.dropFirst()))
        switch result {
        case let .success(text): print(text)
        case let .failure(failure): fail(failure.message)
        }
    }
}

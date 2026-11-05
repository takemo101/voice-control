import Foundation
import VCSkill

struct PickCommand: Command {
    static let info = CommandInfo(
        name: "pick", group: .skills, summary: "候補の中から、依頼に合うものを、Tiny-Jev で選ぶ",
        usage: ["vc pick --query <文字> --option <候補> [--option <候補>…] [--threshold <0〜1>] [--top <件数>]", "<候補を 1 行ずつ出すコマンド> | vc pick --query <文字>"],
        details: [
            "短い 1 行の候補（名前・種類・日付など）と、依頼の文を比べて、確率つきで順位を付ける。**確信できたとき（既定 0.70 以上）だけ「選んだ」**（verdict: picked）、迷えば「迷っている」（ambiguous：利用者に聞く）、合うものがなければ「どれでもない」（none）。",
            "候補は、--option（何回でも）か、標準入力の行。候補が多くても（32 を超えても）、勝ち抜き戦で選ぶ。長い候補は、90 文字で切る。",
            "測定（自作の 16 場面：ファイルの候補）：名前・種類・フォルダでの選択は 14/16。外れたのは、「新しいほう」「古いほう」（日付の大小）：Tiny-Jev は、日付の大小を読めない。日付・順番は、並べ替え（`vc find --oldest`）や番号で扱う。",
            "スキルの中では、`allowed-commands` に `vc pick` を書くと、言語モデルが呼べる。直前の `vc find` の候補（または、直前のコマンドの出力の行）から、利用者の依頼で、選ぶ。",
        ],
        options: [("--query <文字>", "何を選ぶか（依頼の文）"), ("--option <候補>", "候補（何回でも）。なければ、標準入力の行"), ("--threshold <0〜1>", "選んだとみなす確率（既定 0.70）"), ("--top <件数>", "順位を、上位何件まで出すか（既定 5）")],
        examples: ["vc pick --query \"先月の請求書\" --option \"請求書_10月.pdf — 経理（pdf・10/28）\" --option \"請求書_9月.pdf — 経理（pdf・09/30）\"", "ls ~/Documents | vc pick --query 家計簿"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var stdin: String?
        if isatty(STDIN_FILENO) == 0 { stdin = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
        let result = ToolCommands.pick(Array(arguments.remaining.dropFirst()), stdinText: stdin, scorer: context.scorerProvider())
        if result.exitCode == 0 { print(result.output) } else { fail(result.output.replacingOccurrences(of: "error: ", with: "")) }
    }
}

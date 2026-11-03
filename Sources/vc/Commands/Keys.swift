import Foundation
import VCPCControl

struct KeysCommand: Command {
    static let info = CommandInfo(
        name: "keys", group: .settings, summary: "キー操作の JSON 定義の一覧（plan・act の候補）",
        usage: ["vc keys [--keys <dir>]"],
        details: ["組み込みのキー操作と、足した定義（./keys、~/.voice-control/keys、VC_KEYS_DIR、--keys）を表示する。SKILL.md のスキルとは別のもの。"],
        options: [("--keys <dir>", "定義のディレクトリを足す")], examples: ["vc keys"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let skillCatalog = context.skillCatalog
        // vc keys：組み込みのキー操作と、足した定義（JSON。`vc plan`・`vc act` のショートカットの候補）の一覧。
        print(Style.bold("キー操作") + "  組み込み \(Shortcut.all.count) 件・足した定義 \(skillCatalog.shortcuts.count) 件")
        let optionWidth = (skillCatalog.shortcuts.map { displayWidth($0.option) }.max() ?? 0) + 2
        for s in skillCatalog.shortcuts {
            print("  " + pad(s.option, to: optionWidth) + Style.dim("keys=\(s.combo)\(s.app.map { "  app=\($0)" } ?? "")\(s.when.map { "  when=\($0)" } ?? "")") + (s.needsConfirmation ? Style.yellow("  確認つき") : ""))
        }
        if !skillCatalog.problems.isEmpty {
            print("\n" + Style.yellow("読み込めなかった \(skillCatalog.problems.count) 件"))
            skillCatalog.problems.forEach { print("  \($0)") }
        }
    }
}

import Foundation
import VCPCControl

struct EvalContextCommand: Command {
    static let info = CommandInfo(
        name: "eval-context", group: .evaluation, summary: "前の指示を文脈に使うときと使わないときの、当たり率",
        usage: ["vc eval-context <followups.tsv>"],
        details: ["コーパスの形：snapshot<TAB>直前の操作<TAB>期待<TAB>発話。"],
        options: [], examples: ["vc eval-context corpus/followups.tsv"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc eval-context corpus/followups.tsv：前の指示を、文脈に使うときと、使わないときの、当たり率。
        // コーパスの形：snapshot<TAB>直前の操作<TAB>期待<TAB>発話（操作の書き方は、eval と同じ）。
        // try?: コーパスが読めなければ、usage を出して終了する
        let positionals = arguments.positionals
        guard let corpus = positionals.first, let text = try? String(contentsOfFile: corpus, encoding: .utf8) else { fail("usage: vc eval-context <followups.tsv>") }
        let dir = URL(fileURLWithPath: corpus).deletingLastPathComponent()
        // try?: apps.txt（アプリ名の一覧）は、なくてもよい（空の一覧で続ける）
        let apps = ((try? String(contentsOf: dir.appendingPathComponent("apps.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let jev = context.loadJev()
        var hitsWith = 0, hitsWithout = 0, total = 0, wrongSilentWith = 0, wrongSilentWithout = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4 else { continue }   // 空行・形の違う行は、飛ばす
            // try?: 画面（snapshot）が読めなければ、fail する。黙って飛ばすと、当たり率が、実際とずれる
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("snapshots/\(f[0]).json")), let snap = try? SnapshotParser.parse(data) else { fail("snapshot を読めません: \(f[0])") }
            guard let prev = stepFromCanonical(f[1], snapshot: snap) else { fail("直前の操作を作れません: \(f[1])") }
            let planner = Planner(scorer: jev, desktop: ReplayDesktop(snapshot: snap, apps: apps), gate: context.gate, skills: context.skillCatalog.shortcuts, useLocation: !context.options.noLocation)
            let accepted = f[2].split(separator: "|").map(String.init)
            total += 1
            var row = "\(f[1]) → \(f[3])"
            for (name, history) in [("文脈あり", [Executed(step: prev)]), ("文脈なし", [])] {
                let plan = try planner.plan(f[3], history: history)
                let got = plan.verdict == .reject ? "none" : canonical(plan)
                let ok = accepted.contains(got)
                if name == "文脈あり" { if ok { hitsWith += 1 } else if plan.verdict == .execute { wrongSilentWith += 1 } }
                else { if ok { hitsWithout += 1 } else if plan.verdict == .execute { wrongSilentWithout += 1 } }
                row += "  [\(name): \(ok ? "○" : "×") \(got) \(plan.verdict)]"
            }
            print(row + "  （期待 \(f[2])）")
        }
        heading("結果（\(total) 文）")
        kv("文脈あり", "\(hitsWith)/\(total)" + Style.dim("（確認なしの誤り \(wrongSilentWith) 件）"), width: 10)
        kv("文脈なし", "\(hitsWithout)/\(total)" + Style.dim("（確認なしの誤り \(wrongSilentWithout) 件）"), width: 10)
    }
}

import Foundation
import VCDecision
import VCSkill

/// 会話の途中で、発話を、**スキルで実行する（op）か、会話で答える（chat）か**に、振り分けられるかを測る（会話とスキルを混ぜる機能の、土台の測定）。
/// 振り分けは、スキルの選択（`SkillResolver`：当てはまるスキル → 既定スキルへ回すか）の結果：`resolved` なら op・`declined` なら chat。
struct EvalRouteCommand: Command {
    static let info = CommandInfo(
        name: "eval-route", group: .evaluation, summary: "発話を、スキルで実行するか・会話で答えるかに、振り分けられるかの、当たり率を測る",
        usage: ["vc eval-route <hybrid.tsv>"],
        details: ["コーパスの形：正解（op＝操作の依頼・chat＝会話）<TAB>発話。いま有効なスキル（既定スキルを含む）で、`vc run` と同じ選び方をして、実行する（resolved）か・しない（declined）かを数える。実行はしない。"],
        options: [], examples: ["vc eval-route corpus/hybrid.tsv"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        guard let corpus = arguments.positionals.first else { usageError("eval-route", "コーパスを渡してください（例: vc eval-route corpus/hybrid.tsv）") }
        let jev = context.loadJev()
        let skills = context.loadSkills().enabled
        let text: String
        do { text = try String(contentsOfFile: corpus, encoding: .utf8) } catch { fail("読めません: \(corpus)（\(error)）") }
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
        let resolver = SkillResolver(scorer: jev, skills: skills, gate: context.gate)
        var missed: [String] = [], falseRun: [String] = []
        var ops = 0, chats = 0, matched = 0, fallback = 0
        for row in rows {
            let outcome: SkillResolver.Outcome
            do { outcome = try resolver.resolve(row[1]) } catch { fail("\(error)") }
            var runs = false, label = ""
            if case let .resolved(resolution) = outcome {
                runs = true
                label = "\(resolution.skill.name)・\(pct(resolution.probability))"
                if resolution.kind == .matched { matched += 1 } else { fallback += 1 }
            }
            if row[0] == "op" { ops += 1; if !runs { missed.append(row[1]) } } else { chats += 1; if runs { falseRun.append("\(row[1])（\(label)）") } }
        }
        heading("振り分け（スキルで実行＝op・会話＝chat）")
        kv("操作の依頼", "\(ops - missed.count)/\(ops) を、スキルで実行へ", width: 10)
        kv("会話", "\(chats - falseRun.count)/\(chats) を、会話のまま", width: 10)
        kv("実行の内訳", "スキルに一致 \(matched)・既定スキルへ \(fallback)", width: 10)
        if !missed.isEmpty { kv("取りこぼし", missed.joined(separator: "・"), width: 10) }
        if !falseRun.isEmpty { kv("誤実行", falseRun.joined(separator: "・"), width: 10) }
    }
}

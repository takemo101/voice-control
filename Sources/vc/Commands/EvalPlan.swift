import Foundation
import VCDecision
import VCSkill

struct EvalPlanCommand: Command {
    static let info = CommandInfo(
        name: "eval-plan", group: .evaluation, summary: "依頼を、複数のステップに分ける判断（言語モデル）と、各ステップのスキルの選び方の、当たり率を測る",
        usage: ["vc eval-plan <plan.tsv> [--set dev|test]"],
        details: [
            "コーパスの形：集合（dev・test）<TAB>正解のスキル列（`>` 区切り）<TAB>依頼<TAB>（任意）分けたとき、ステップに残るべき名前（`,` 区切り。エージェント・サイトの名前）。依頼を、言語モデル（vc engine）が分け、各ステップを Tiny-Jev が選んだスキルの列が、正解と合うかを数える（実行はしない）。",
            "dev は、分け方の指示文を調整するときに使う集合、test は、調整に使わず、最後に測る集合。**dev で調整して、test で測る**（同じ文で、調整と評価をしない）。",
            "「まとめて一致」は、同じスキルの連続を 1 つにまとめて比べる（「音量を下げて次の曲」を、spotify 2 つに分けても、同じこと）。",
        ],
        options: [("--set <dev|test>", "この集合だけを測る（なければ、両方を、別々に）")],
        examples: ["vc eval-plan corpus/plan.tsv --set dev", "vc eval-plan corpus/plan.tsv --set test"])

    private struct Row { let set: String; let expected: [String]; let utterance: String; let keep: [String] }

    private static func collapse(_ names: [String]) -> [String] {
        var out: [String] = []
        for name in names where out.last != name { out.append(name) }
        return out
    }

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let onlySet = arguments.option("--set")
        guard let corpus = arguments.positionals.first else { usageError("eval-plan", "コーパスを渡してください（例: vc eval-plan corpus/plan.tsv --set dev）") }
        let text: String
        do { text = try String(contentsOfFile: corpus, encoding: .utf8) } catch { fail("読めません: \(corpus)（\(error)）") }
        let rows: [Row] = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { line in
            let cols = line.split(separator: "\t", maxSplits: 3).map(String.init)
            return cols.count >= 3 ? Row(set: cols[0], expected: cols[1].split(separator: ">").map(String.init), utterance: cols[2], keep: cols.count > 3 ? cols[3].split(separator: ",").map(String.init) : []) : nil
        }.filter { onlySet == nil || $0.set == onlySet }
        guard !rows.isEmpty else { fail("測る行がありません（--set \(onlySet ?? "(両方)")）") }

        requireAppleIntelligence(for: context.engine)
        let skills = context.loadSkills()
        skills.reportProblems()
        let enabled = skills.enabled
        let jev = context.loadJev()
        let planner = LLMPlanner(engine: context.engine, skills: enabled)
        let resolver = SkillResolver(scorer: jev, skills: enabled, gate: context.gate)

        for set in ["dev", "test"] where onlySet == nil || onlySet == set {
            let mine = rows.filter { $0.set == set }
            if mine.isEmpty { continue }
            var countOK = 0, strictOK = 0, collapsedOK = 0, over = 0, under = 0, keepTotal = 0, keepLost = 0, oversplitRows = 0, oversplitSteps = 0
            var rejections: [String: Int] = [:]
            var times: [Double] = []
            var misses: [String] = []
            for row in mine {
                let t0 = Date()
                let decision: PlanDecision
                do { decision = try await planner.plan(row.utterance) } catch { fail("\(error)") }
                times.append(Date().timeIntervalSince(t0))
                if let reason = decision.rejection { rejections["\(reason)", default: 0] += 1 }
                let steps: [String]
                if case let .steps(s) = decision.plan { steps = s } else { steps = [row.utterance] }
                var actual: [String] = []
                for step in steps {
                    do {
                        switch try resolver.resolve(step) {
                        case let .resolved(r): actual.append(r.skill.name)
                        case .declined: actual.append("none")
                        }
                    } catch { fail("\(error)") }
                }
                // 固有名（エージェント・アプリ・サイトの名前）が、ステップに残ったか（分けたときだけ）
                if steps.count > 1 { for name in row.keep { keepTotal += 1; if !steps.contains(where: { $0.contains(name) }) { keepLost += 1; misses.append("\(row.utterance)  「\(name)」が、ステップから落ちた") } } }
                // 分けすぎ（厳密）：正解の列の長さより、ステップが多い（同じスキルの連続も、数える）
                if steps.count > row.expected.count { oversplitRows += 1; oversplitSteps += steps.count - row.expected.count; misses.append("\(row.utterance)  分けすぎ：\(row.expected.count) → \(steps.count)（\(steps.joined(separator: " / "))）") }
                let expectedCollapsed = Self.collapse(row.expected)
                let actualCollapsed = Self.collapse(actual)
                if actualCollapsed.count == expectedCollapsed.count { countOK += 1 }
                if actualCollapsed.count > expectedCollapsed.count { over += 1 }
                if actualCollapsed.count < expectedCollapsed.count { under += 1 }
                if actual == row.expected { strictOK += 1 }
                if actualCollapsed == expectedCollapsed { collapsedOK += 1 } else { misses.append("\(row.utterance)  正解 \(row.expected.joined(separator: ">"))／実際 \(actual.joined(separator: ">"))\(steps.count > 1 ? "（\(steps.count) 分割）" : "")") }
            }
            heading("\(set)（\(mine.count) 文・エンジン \(context.engineText ?? "apple")）")
            kv("ステップ数が合う", "\(countOK)/\(mine.count)（分けすぎ \(over)・取りこぼし \(under)）", width: 14)
            kv("分けすぎ（厳密）", "\(oversplitRows)/\(mine.count) 文（余計なステップ \(oversplitSteps)）", width: 14)
            kv("スキル列がまとめて一致", "\(collapsedOK)/\(mine.count)", width: 14)
            kv("スキル列が厳密に一致", "\(strictOK)/\(mine.count)", width: 14)
            if keepTotal > 0 { kv("固有名が残った", "\(keepTotal - keepLost)/\(keepTotal)", width: 14) }
            let sorted = times.sorted()
            kv("分ける呼び出し", String(format: "平均 %.2f 秒・最大 %.2f 秒", times.reduce(0, +) / Double(times.count), sorted.last ?? 0), width: 14)
            if !rejections.isEmpty { kv("検査で、分けなかった", rejections.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: "・"), width: 14) }
            for miss in misses { print("  " + Style.dim("✗ " + miss)) }
        }
    }
}

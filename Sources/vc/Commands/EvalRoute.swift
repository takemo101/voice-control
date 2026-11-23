import Foundation
import FoundationModels
import VCDecision
import VCSkill

/// 会話の途中で、発話を、**スキルで実行する（op）か、会話で答える（chat）か**に、振り分けられるかを測る（会話とスキルを混ぜる機能の、土台の測定）。
/// 振り分けは、スキルの選択（`SkillResolver`：当てはまるスキル → 既定スキルへ回すか）の結果：`resolved` なら op・`declined` なら chat。
struct EvalRouteCommand: Command {
    static let info = CommandInfo(
        name: "eval-route", group: .evaluation, summary: "発話を、スキルで実行するか・会話で答えるかに、振り分けられるかの、当たり率を測る",
        usage: ["vc eval-route <hybrid.tsv> [--llm-picks]"],
        details: ["コーパスの形：正解（op＝操作の依頼・chat＝会話）<TAB>発話。いま有効なスキル（既定スキルを含む）で、`vc run` と同じ選び方をして、実行する（resolved）か・しない（declined）かを数える。実行はしない。"],
        options: [("--llm-picks", "Tiny-Jev のかわりに、Apple のモデルが、会話の中で、スキルを呼ぶか（道具 use_skill を呼ぶか）で、振り分ける")], examples: ["vc eval-route corpus/hybrid.tsv"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let modelPicks = arguments.flag("--llm-picks")
        guard let corpus = arguments.positionals.first else { usageError("eval-route", "コーパスを渡してください（例: vc eval-route corpus/hybrid.tsv）") }
        let skills = context.loadSkills().enabled
        let text: String
        do { text = try String(contentsOfFile: corpus, encoding: .utf8) } catch { fail("読めません: \(corpus)（\(error)）") }
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
        if modelPicks {
            try await runModelPicks(rows: rows, skills: skills)
            return
        }
        let jev = context.loadJev()
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

    /// 会話のモデル（Apple）が、スキルを呼ぶ道具を、自分で呼ぶかで振り分ける（Jev を使わない案の、測定）。道具は、呼ばれたことを記録するだけ（実行しない）。
    private func runModelPicks(rows: [[String]], skills: [Skill]) async throws {
        guard case .available = SystemLanguageModel.default.availability else { fail("Apple のモデルが使えません") }
        let catalog = skills.filter { $0.name != DefaultSkill.name }.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let instructions = """
        You are a Mac assistant that talks with the user in Japanese. Answer briefly.
        """ + """

        You can also operate the user's Mac by calling the tool use_skill. Available skills:
        \(catalog)
        - default: open or close apps, press buttons, type text, scroll, take screenshots, change the volume (anything else on the Mac).
        When the user asks you to DO something on the computer (open, close, play, change the volume, take a screenshot, find or open files...), you MUST call use_skill immediately: never ask for confirmation, never reply with words only, never tell the user to do it themselves. For questions, explanations, opinions, small talk, or asking HOW to do something, just answer in words and never call it.
        """
        var missed: [String] = [], falseRun: [String] = []
        var ops = 0, chats = 0
        for row in rows {
            let probe = SkillCallProbe()
            let session = LanguageModelSession(tools: [probe], instructions: instructions)
            do { _ = try await session.respond(to: row[1]) } catch { FileHandle.standardError.write(Data("ERR \(row[1]): \(error)\n".utf8)) }
            let runs = probe.calls > 0
            if row[0] == "op" { ops += 1; if !runs { missed.append(row[1]) } } else { chats += 1; if runs { falseRun.append("\(row[1])（\(probe.lastSkill)）") } }
        }
        heading("振り分け：Apple のモデルが、スキルを呼ぶか")
        kv("操作の依頼", "\(ops - missed.count)/\(ops) を、スキルの呼び出しへ", width: 10)
        kv("会話", "\(chats - falseRun.count)/\(chats) を、会話のまま", width: 10)
        if !missed.isEmpty { kv("取りこぼし", missed.joined(separator: "・"), width: 10) }
        if !falseRun.isEmpty { kv("誤実行", falseRun.joined(separator: "・"), width: 10) }
    }
}

private final class SkillCallProbe: Tool, @unchecked Sendable {
    let name = "use_skill"
    let description = "Run a skill to operate the user's Mac. Only for requests to do something on the computer."
    private(set) var calls = 0
    private(set) var lastSkill = ""
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(name: "UseSkillArgs", description: "arguments", properties: [
            .init(name: "skill", description: "the skill name", schema: DynamicGenerationSchema(type: String.self), isOptional: false),
            .init(name: "request", description: "what to do, in the user's words", schema: DynamicGenerationSchema(type: String.self), isOptional: false),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }
    func call(arguments: GeneratedContent) async throws -> String {
        calls += 1
        lastSkill = (try? arguments.value(String.self, forProperty: "skill")) ?? "?"
        return "Done."
    }
}

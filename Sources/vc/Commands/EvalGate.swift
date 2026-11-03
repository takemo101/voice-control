import Foundation
import VCDecision
import VCSkill

struct EvalGateCommand: Command {
    static let info = CommandInfo(
        name: "eval-gate", group: .evaluation, summary: "「操作の依頼か」の判定（既定スキルに回すか）の、当たり率を測る",
        usage: ["vc eval-gate <gate.tsv>"],
        details: ["コーパスの形：正解（op＝操作の依頼・chat＝会話や独り言）<TAB>発話。操作の依頼を、既定スキルへ回せたか・会話を止めたかを数え、取りこぼしと誤通過を出す。"],
        options: [], examples: ["vc eval-gate corpus/gate.tsv"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc eval-gate <gate.tsv>：「操作の依頼か」の判定（既定スキルに回すか）の、当たり率。正解（op・chat）つきの文で測る。
        guard let corpus = arguments.positionals.first else { usageError("eval-gate", "コーパスを渡してください（例: vc eval-gate corpus/gate.tsv）") }
        let jev = context.loadJev()
        let text: String
        do { text = try String(contentsOfFile: corpus, encoding: .utf8) } catch { fail("読めません: \(corpus)（\(error)）") }
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
        var missed: [String] = [], passedChat: [String] = []
        var ops = 0, chats = 0
        for row in rows {
            let p: Double
            do { p = try SkillResolver.actionableProbability(scorer: jev, request: row[1]) } catch { fail("\(error)") }
            let passes = p >= DefaultSkill.actionableThreshold
            if row[0] == "op" { ops += 1; if !passes { missed.append("\(row[1])（\(pct(p))）") } } else { chats += 1; if passes { passedChat.append("\(row[1])（\(pct(p))）") } }
        }
        heading("操作の依頼か（しきい値 \(pct(DefaultSkill.actionableThreshold))）")
        kv("操作の依頼", "\(ops - missed.count)/\(ops) を、既定スキルへ回した", width: 10)
        kv("会話・独り言", "\(chats - passedChat.count)/\(chats) を、止めた", width: 10)
        if !missed.isEmpty { kv("取りこぼし", missed.joined(separator: "・"), width: 10) }
        if !passedChat.isEmpty { kv("誤通過", passedChat.joined(separator: "・"), width: 10) }
    }
}

import Foundation
import VCDecision
import VCSkill

struct EvalImageCommand: Command {
    static let info = CommandInfo(
        name: "eval-image", group: .evaluation, summary: "会話で、撮ったスクリーンショットを使うかの判定（Tiny-Jev）の、当たり率を測る",
        usage: ["vc eval-image <chat-image.tsv> [--threshold <確率>] [--list]"],
        details: ["コーパスの形：正解（img＝画像について・no＝画像なしで答えられる）<TAB>直前のやり取り（記録用。判定には、渡さない）<TAB>発話。画像を使う側の確率が、しきい値以上なら、使う。"],
        options: [("--list", "1 文ごとの確率も出す"), ("--threshold <確率>", "使うしきい値（既定は、本番と同じ）")],
        examples: ["vc eval-image corpus/chat-image.tsv"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        guard let corpus = arguments.positionals.first else { usageError("eval-image", "コーパスを渡してください（例: vc eval-image corpus/chat-image.tsv）") }
        let list = arguments.flag("--list")
        let threshold = arguments.option("--threshold").flatMap(Double.init) ?? ChatImageUse.threshold
        let jev = context.loadJev()
        let judge = ChatImageUse(scorer: jev)
        let text: String
        do { text = try String(contentsOfFile: corpus, encoding: .utf8) } catch { fail("読めません: \(corpus)（\(error)）") }
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", maxSplits: 2).map(String.init) }.filter { $0.count == 3 }
        var missed: [String] = [], wrongly: [String] = []
        var imgs = 0, nos = 0
        for row in rows {
            let p: Double
            do { p = try judge.probability(request: row[2]) } catch { fail("\(error)") }
            if list { print("\(row[0])\t\(String(format: "%.4f", p))\t\(row[2])") }
            let uses = p >= threshold
            if row[0] == "img" { imgs += 1; if !uses { missed.append("\(row[2])（\(pct(p))）") } } else { nos += 1; if uses { wrongly.append("\(row[2])（\(pct(p))）") } }
        }
        heading("撮った画像を使うか（しきい値 \(pct(threshold))）")
        kv("画像について", "\(imgs - missed.count)/\(imgs) を、使った", width: 10)
        kv("画像なし", "\(nos - wrongly.count)/\(nos) を、使わなかった", width: 10)
        if !missed.isEmpty { kv("取りこぼし", missed.joined(separator: "・"), width: 10) }
        if !wrongly.isEmpty { kv("誤って使った", wrongly.joined(separator: "・"), width: 10) }
    }
}

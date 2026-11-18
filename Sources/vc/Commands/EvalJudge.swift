import Foundation
import VCDecision
import VCSkill

/// 会話の判断（Tiny-Jev）の、当たり率を測る：撮ったスクリーンショットを使うか（`image`）・最新の情報（Web）が要るか（`web`）。
struct EvalJudgeCommand: Command {
    static let info = CommandInfo(
        name: "eval-judge", group: .evaluation, summary: "会話の判断（撮った画像を使うか・Web が要るか）の、当たり率を測る",
        usage: ["vc eval-judge <image|web|source|command|command-auto> <コーパス.tsv> [--threshold <確率>] [--list]"],
        details: ["コーパスの形：正解<TAB>（image は、直前のやり取り〔記録用。判定には渡さない〕<TAB>）発話。正解は、image：img（画像について）・no、web：web（最新の情報が要る）・no。確率が、しきい値以上なら、「要る・使う」と判定する。"],
        options: [("--list", "1 文ごとの確率も出す"), ("--jev-threshold <確率>", "command-auto で、Jev の「無害」のしきい値（既定は、本番と同じ）"), ("--threshold <確率>", "しきい値（既定は、本番と同じ）")],
        examples: ["vc eval-judge image corpus/chat-image.tsv", "vc eval-judge web corpus/chat-web.tsv"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        guard arguments.positionals.count >= 2 else { usageError("eval-judge", "種類（image・web・source）とコーパスを渡してください（例: vc eval-judge web corpus/chat-web.tsv）") }
        let kind = arguments.positionals[0], corpus = arguments.positionals[1]
        let list = arguments.flag("--list")
        let jev = context.loadJev()
        if kind == "source" { try evalSource(corpus: corpus, jev: jev, threshold: arguments.option("--threshold").flatMap(Double.init) ?? ImageSourceChoice.threshold, list: list); return }
        let positive: String, title: String, defaultThreshold: Double
        let probability: (String) throws -> Double
        switch kind {
        case "image":
            positive = "img"; title = "撮った画像を使うか"; defaultThreshold = ChatImageUse.threshold
            let judge = ChatImageUse(scorer: jev); probability = { try judge.probability(request: $0) }
        case "web":
            positive = "web"; title = "最新の情報（Web）が要るか"; defaultThreshold = ChatWebNeed.threshold
            let judge = ChatWebNeed(scorer: jev); probability = { try judge.probability(request: $0) }
        case "command":
            positive = "safe"; title = "コマンドが無害か（自動モードで、確認を省いてよいか）"; defaultThreshold = CommandSafetyJudge.threshold
            let judge = CommandSafetyJudge(scorer: jev); probability = { try judge.probability(command: $0) }
        case "command-auto":   // 規則（許可リスト・危ない名前・場所・語）→ Jev の全体。確認を省くか（確率ではなく、0 か 1）
            positive = "safe"; title = "自動モードの全体（規則 → Jev）で、確認を省くか"; defaultThreshold = 0.5
            let judge = CommandSafetyJudge(scorer: jev); let line = arguments.option("--jev-threshold").flatMap(Double.init) ?? CommandSafetyJudge.threshold
            probability = { judge.skipsConfirmation($0, threshold: line) ? 1 : 0 }
        default: usageError("eval-judge", "知らない種類: \(kind)（image・web・source・command・command-auto）")
        }
        let threshold = arguments.option("--threshold").flatMap(Double.init) ?? defaultThreshold
        let text: String
        do { text = try String(contentsOfFile: corpus, encoding: .utf8) } catch { fail("読めません: \(corpus)（\(error)）") }
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t").map(String.init) }.filter { $0.count >= 2 }
        var missed: [String] = [], wrongly: [String] = []
        var positives = 0, negatives = 0
        for row in rows {
            let utterance = row[row.count - 1]
            let p: Double
            do { p = try probability(utterance) } catch { fail("\(error)") }
            if list { print("\(row[0])\t\(String(format: "%.4f", p))\t\(utterance)") }
            let yes = p >= threshold
            if row[0] == positive { positives += 1; if !yes { missed.append("\(utterance)（\(pct(p))）") } } else { negatives += 1; if yes { wrongly.append("\(utterance)（\(pct(p))）") } }
        }
        heading("\(title)（しきい値 \(pct(threshold))）")
        if kind == "command" || kind == "command-auto" {
            // 大事なのは、「無害でない」を、無害と判定してしまう数（確認なしで、実行される）。無害を、無害と判定できない（確認が増える）のは、安全側の誤り
            kv("無害（safe）", "\(positives - missed.count)/\(positives) を、無害と判定した（残りは、確認に回る）", width: 12)
            kv("無害でない（harm）", "\(negatives - wrongly.count)/\(negatives) を、確認に回した", width: 12)
            if !wrongly.isEmpty { kv("**危険な誤り**", "無害と判定してしまった：" + wrongly.joined(separator: "・"), width: 12) }
            if !missed.isEmpty { kv("確認に回った無害", missed.joined(separator: "・"), width: 12) }
            return
        }
        kv("要る・使う側", "\(positives - missed.count)/\(positives) を、そう判定した", width: 10)
        kv("要らない側", "\(negatives - wrongly.count)/\(negatives) を、そう判定しなかった", width: 10)
        if !missed.isEmpty { kv("取りこぼし", missed.joined(separator: "・"), width: 10) }
        if !wrongly.isEmpty { kv("誤判定", wrongly.joined(separator: "・"), width: 10) }
    }

    /// スクリーンショットも、コピーした画像も、あるとき：依頼が、どちらの画像についてか（3 択）。
    private func evalSource(corpus: String, jev: TinyJev, threshold: Double, list: Bool) throws {
        let choice = ImageSourceChoice(scorer: jev)
        let text: String
        do { text = try String(contentsOfFile: corpus, encoding: .utf8) } catch { fail("読めません: \(corpus)（\(error)）") }
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t").map(String.init) }.filter { $0.count >= 2 }
        var right = 0, wrong = 0, abstained = 0, total = 0, undecidedPicked = 0, undecided = 0
        var wrongs: [String] = []
        for row in rows {
            let p: [Double]
            do { p = try choice.probabilities(request: row[1]) } catch { fail("\(error)") }
            let picked = ImageSourceChoice.decide(p, threshold: threshold)
            if list { print("\(row[0])\t\(p.map { String(format: "%.3f", $0) }.joined(separator: ","))\t\(row[1])") }
            switch row[0] {
            case "any": undecided += 1; if picked != nil { undecidedPicked += 1 }
            default:
                total += 1
                let expected: ImageSource = row[0] == "shot" ? .screenshot : .clipboard
                if picked == expected { right += 1 } else if picked == nil { abstained += 1 } else { wrong += 1; wrongs.append("\(row[1])（\(row[0]) → \(picked == .clipboard ? "clip" : "shot")）") }
            }
        }
        heading("スクリーンショットか、コピーした画像か（しきい値 \(pct(threshold))）")
        kv("手がかりあり", "\(right)/\(total) を、正しく選んだ・\(wrong) を、取り違えた・\(abstained) は、決めなかった（言葉に戻る）", width: 10)
        kv("手がかりなし", "\(undecided - undecidedPicked)/\(undecided) を、決めなかった（言葉に戻る）", width: 10)
        if !wrongs.isEmpty { kv("取り違え", wrongs.joined(separator: "・"), width: 10) }
    }
}

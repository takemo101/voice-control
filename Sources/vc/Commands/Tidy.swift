import Foundation
import VCSkill

/// `vc tidy "<文字>"`：整理モード（SPEC F79）を、この文字で試す（設定の整え方・エンジンを、そのまま使う）。整える前と後・検査の結果を出す。**入力はしない**（診断）。
struct TidyCommand: Command {
    static let info = CommandInfo(
        name: "tidy", group: .evaluation, summary: "整理モードを、渡した文字で試す（入力はしない。整える前と後・検査の結果を出す）",
        usage: ["vc tidy <文字> [--instructions <整え方>]"],
        details: ["設定の「整え方」（設定 > 音声入力 > 整理）と、スキルを実行するモデル（設定 > モデル）を、そのまま使う。--instructions で、その場だけ、整え方を替えられる。数字・否定・長さの検査に通らなければ、「元の文字を入れる」と出す。"],
        options: [("--instructions <整え方>", "整え方の指示（既定：設定の値。設定がなければ、組み込みの既定）")],
        examples: ["vc tidy \"えーと明日の会議は3時、いや4時からです\""])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let instructions = arguments.option("--instructions") ?? context.currentSettings().tidyInstructions
        guard let text = arguments.positionals.first else { usageError("tidy", "整える文字を渡してください（例: vc tidy \"えーと明日の会議は3時、いや4時からです\"）") }
        requireAppleIntelligence(for: context.engine)
        let started = Date()
        let result = await Tidier(engine: context.engine, instructionsSetting: instructions).tidy(text)
        heading("整理")
        kv("元", text, width: 6)
        switch result {
        case let .tidied(tidied): kv("結果", Style.green(tidied), width: 6)
        case let .kept(original, reason):
            kv("結果", Style.yellow(original) + Style.dim("（元の文字のまま）"), width: 6)
            kv("理由", reason.map { "\($0)" } ?? "短いので、整理しません", width: 6)
        }
        kv("時間", String(format: "%.1f 秒", Date().timeIntervalSince(started)), width: 6)
    }
}

/// `vc eval-tidy <tsv>`：整理モードの、当たり率を測る。形：`元の文字<TAB>入っていてほしい語（| 区切り）<TAB>入っていてほしくない語（| 区切り）`。
/// 数える：**直せた**（入っていてほしい語が、すべて入り、ほしくない語が、1 つもない）・**元のまま**（検査で、元に戻した：理由別）。
struct EvalTidyCommand: Command {
    static let info = CommandInfo(
        name: "eval-tidy", group: .evaluation, summary: "整理モードの、当たり率を測る（作り物の言い間違い文で、直せた割合・元に戻した理由）",
        usage: ["vc eval-tidy <tidy.tsv> [--rounds <回数>]"],
        details: ["コーパスの形：元の文字<TAB>入っていてほしい語（| 区切り）<TAB>入っていてほしくない語（| 区切り）。整理して、入っていてほしい語が、すべて入り、ほしくない語が、1 つもなければ、「直せた」。検査で、元の文字に戻したものは、理由別に数える（元の文字は、ほしくない語を含むので、「直せた」には、ならない）。"],
        options: [("--rounds <回数>", "1 文あたりの回数（既定 1）")], examples: ["vc eval-tidy corpus/tidy.tsv"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let rounds = max(1, arguments.option("--rounds").flatMap(Int.init) ?? 1)
        guard let corpus = arguments.positionals.first else { usageError("eval-tidy", "コーパスを渡してください（例: vc eval-tidy corpus/tidy.tsv）") }
        requireAppleIntelligence(for: context.engine)
        let text: String
        do { text = try String(contentsOfFile: corpus, encoding: .utf8) } catch { fail("読めません: \(corpus)（\(error)）") }
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }.filter { $0.count >= 2 }
        let tidier = Tidier(engine: context.engine, instructionsSetting: context.currentSettings().tidyInstructions)
        var fixed = 0, total = 0, kept: [String: Int] = [:]
        var failures: [String] = []
        var seconds = 0.0
        for row in rows {
            let must = row[1].split(separator: "|").map(String.init), mustNot = row.count > 2 ? row[2].split(separator: "|").map(String.init) : []
            for _ in 0..<rounds {
                total += 1
                let started = Date()
                let result = await tidier.tidy(row[0])
                seconds += Date().timeIntervalSince(started)
                if case let .kept(_, reason) = result { kept[reason.map { "\($0)" } ?? "短い", default: 0] += 1 }
                let out = result.text
                if must.allSatisfy(out.contains) && !mustNot.contains(where: out.contains) { fixed += 1 }
                else { failures.append("\(row[0])\n      → \(out)\(result == .tidied(out) ? "" : "（元のまま）")") }
            }
        }
        heading("整理（\(total) 件）")
        kv("直せた", "\(fixed)/\(total)（\(Int((Double(fixed) / Double(max(total, 1)) * 100).rounded()))%）", width: 10)
        if !kept.isEmpty { kv("元のまま", kept.sorted { $0.value > $1.value }.map { "\($0.key)：\($0.value)" }.joined(separator: "・"), width: 10) }
        kv("平均", String(format: "%.1f 秒/件", seconds / Double(max(total, 1))), width: 10)
        for failure in Set(failures).sorted() { print("  ✗ " + failure) }
    }
}

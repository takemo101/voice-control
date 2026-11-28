import Foundation
import VCCore
import VCSkill

/// 会議の文字起こし（`相手: …` `自分: …` の行）を読む（要約の確認・測定用の、開発コマンドが、共有する）。
private func readMeeting(_ path: String) -> (lines: [SummaryLine], header: [String: String]) {
    let text: String
    do { text = try String(contentsOfFile: path, encoding: .utf8) } catch { fail("読めません: \(path)（\(error)）") }
    var header: [String: String] = [:]
    var lines: [SummaryLine] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = String(raw)
        if line.hasPrefix("#") {
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            if let colon = body.firstIndex(of: ":") { header[String(body[..<colon])] = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            continue
        }
        guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
        lines.append(SummaryLine(speaker: String(line[..<colon]), text: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
    }
    return (lines, header)
}

/// `vc summary <文字起こし.txt> [--focus <テーマ>] [--instructions <指示>]`：会議の要約を、試す（開発・確認用）。
struct SummaryCommand: Command {
    static let info = CommandInfo(
        name: "summary", group: .evaluation, summary: "会議の文字起こし（相手: … / 自分: … の行）を、要約する（試す）",
        usage: ["vc summary <文字起こし.txt> [--focus <テーマ>] [--instructions <指示>]"],
        details: ["設定の「要約のまとめ方」（設定 > 音声入力（会議））と、スキルを実行するモデル（設定 > モデル）を使う。話にない数字が出た要約は、出さない。"],
        options: [("--focus <テーマ>", "そのテーマの話だけ要約する"), ("--instructions <指示>", "まとめ方の指示（設定を上書き。この実行だけ）")],
        examples: ["vc summary corpus/summary/01-release.txt"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let focus = arguments.option("--focus")
        let instructions = arguments.option("--instructions") ?? context.currentSettings().summaryInstructions
        guard let path = arguments.positionals.first else { usageError("summary", "文字起こしのファイルを渡してください") }
        requireAppleIntelligence(for: context.engine)
        let meeting = readMeeting(path)
        let started = Date()
        let result = await Summarizer(engine: context.engine, instructionsSetting: instructions).summarize(meeting.lines, focus: focus)
        heading("要約")
        kv("エンジン", context.engine.server == nil ? "Apple のモデル" : "ローカルのサーバー", width: 6)
        kv("発話", "\(meeting.lines.count) 件", width: 6)
        switch result {
        case let .summary(text): print(Style.green(text))
        case .nothingRelevant: kv("結果", "該当する話は、ありませんでした", width: 6)
        case let .failed(why): kv("結果", Style.yellow("\(why)"), width: 6)
        }
        kv("時間", String(format: "%.1f 秒", Date().timeIntervalSince(started)), width: 6)
    }
}

/// `vc eval-summary <フォルダ> [--rounds N]`：要約の、確認の測定。各ファイルの先頭の `# must: a|b`（入っていてほしい語）・`# mustnot: x|y`（入っていてほしくない語）・`# focus: テーマ`・`# expect: nothing`（該当なし）で、合否。
struct EvalSummaryCommand: Command {
    static let info = CommandInfo(
        name: "eval-summary", group: .evaluation, summary: "会議の要約の、確認の測定（作り物の会議。語の有無で、合否）",
        usage: ["vc eval-summary <フォルダ> [--rounds <回数>]"],
        details: ["フォルダの `*.txt`（`相手: …` の行）を、順に要約して、`# must`・`# mustnot`・`# expect` で、合否を数える。**使ったエンジンが、結果に出る**。"],
        options: [("--rounds <回数>", "1 件あたりの回数（既定 1）")], examples: ["vc eval-summary corpus/summary"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let rounds = max(1, arguments.option("--rounds").flatMap(Int.init) ?? 1)
        guard let folder = arguments.positionals.first else { usageError("eval-summary", "フォルダを渡してください（例: vc eval-summary corpus/summary）") }
        requireAppleIntelligence(for: context.engine)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".txt") }.sorted()
        guard !files.isEmpty else { fail("測るファイルが、ありません: \(folder)") }
        let summarizer = Summarizer(engine: context.engine, instructionsSetting: context.currentSettings().summaryInstructions)
        var passed = 0, total = 0, seconds = 0.0
        var failures: [String] = []
        for file in files {
            let meeting = readMeeting((folder as NSString).appendingPathComponent(file))
            let must = (meeting.header["must"] ?? "").split(separator: "|").map(String.init), mustNot = (meeting.header["mustnot"] ?? "").split(separator: "|").map(String.init)
            for _ in 0..<rounds {
                total += 1
                let started = Date()
                let result = await summarizer.summarize(meeting.lines, focus: meeting.header["focus"])
                seconds += Date().timeIntervalSince(started)
                var ok = false, shown = ""
                switch result {
                case let .summary(text):
                    shown = text
                    ok = meeting.header["expect"] != "nothing" && must.allSatisfy(text.contains) && !mustNot.contains(where: text.contains)
                case .nothingRelevant:
                    shown = "（該当なし）"; ok = meeting.header["expect"] == "nothing"
                case let .failed(why):
                    shown = "（失敗：\(why)）"
                }
                if ok { passed += 1 } else { failures.append("\(file)\n      → \(shown.replacingOccurrences(of: "\n", with: " / "))") }
            }
        }
        heading("要約（\(total) 件）")
        kv("エンジン", context.engine.server == nil ? "Apple のモデル" : "ローカルのサーバー", width: 10)
        kv("合格", "\(passed)/\(total)（\(Int((Double(passed) / Double(max(total, 1)) * 100).rounded()))%）", width: 10)
        kv("平均", String(format: "%.1f 秒/件", seconds / Double(max(total, 1))), width: 10)
        for failure in failures { print("  ✗ " + failure) }
    }
}

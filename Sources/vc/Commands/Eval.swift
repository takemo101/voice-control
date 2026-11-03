import Foundation
import VCPCControl
import VCSpeech

struct EvalCommand: Command {
    static let info = CommandInfo(
        name: "eval", group: .evaluation, summary: "固定した画面での、操作の当たり率を測る（実機は操作しない）",
        usage: ["vc eval <plans.tsv> [--speak] [--llm] [--no-location]"],
        details: [
            "コーパスの形：snapshot<TAB>期待<TAB>発話。画面は、コーパスと同じ場所の snapshots/<名前>.json、アプリの一覧は apps.txt。",
            "確認なしで実行してしまった誤りの数も出す。",
        ],
        options: [
            ("--speak", "発話を say で合成し、文字起こしを通す（聞き違いも込みで測る）"),
            ("--llm", "同じ文を、Apple の言語モデルにも選ばせて、比べる"),
            ("--no-location", "位置情報なしで測る（比較用）"),
        ],
        examples: ["vc eval corpus/plans.tsv", "vc eval corpus/plans.tsv --no-location"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // コーパスの形：snapshot<TAB>期待<TAB>発話。期待は open:<アプリ> click:<要素名> type:<文字> press:<キー> scroll:<向き> none（`PCEval`）。
        // snapshot は corpus/snapshots/<名前>.json（自作の fixture を agent-desktop で撮ったもの）。アプリの一覧は corpus/apps.txt。
        // try?: コーパスが読めなければ、usage を出して終了する
        guard let corpus = arguments.positionals.first, let text = try? String(contentsOfFile: corpus, encoding: .utf8) else { fail("usage: vc eval <plans.tsv>") }
        let dir = URL(fileURLWithPath: corpus).deletingLastPathComponent()
        let apps = PCEval.apps(in: dir)
        let jev = context.loadJev()
        var snapshots: [String: Snapshot] = [:]
        var tally = PCEval.Tally()
        var llmTally = PCEval.LLMTally()
        var heard = 0, misheard = 0
        var millis: [Double] = []
        var llmMillis: [Double] = []
        for f in PCEval.rows(in: text, columns: 3) {
            if snapshots[f[0]] == nil {
                guard let s = PCEval.snapshot(named: f[0], in: dir) else { fail("snapshot を読めません: \(f[0])") }
                snapshots[f[0]] = s
            }
            let snapshot = snapshots[f[0]]!
            let planner = Planner(scorer: jev, desktop: ReplayDesktop(snapshot: snapshot, apps: apps), gate: context.gate, skills: context.skillCatalog.shortcuts, useLocation: !context.options.noLocation)
            let t0 = Date()
            let plan: Plan
            var utterance = f[2]
            if context.options.speak {
                // 合成音声（say）→ 文字起こし。聞き違いも込みで測る。合成音声は、きれいなので、実際の声より楽観的。
                do { utterance = try await speakAndTranscribe(f[2]) } catch { fail("\(error)") }
                heard += 1
                if utterance != f[2] { misheard += 1 }
            }
            do { plan = try planner.plan(utterance) } catch { fail("\(error)") }
            millis.append(Date().timeIntervalSince(t0) * 1000)
            let judgement = PCEval.judge(plan, expected: f[1], snapshot: snapshot)
            tally.record(judgement)
            if !judgement.hit {
                print(Style.red("MISS") + " \(plan.verdict) \(judgement.got) ≠ \(f[1]) [\(f[0])]: \(f[2])" + (utterance != f[2] ? " (聞こえ: \(utterance))" : "") + "  ← \(plan.choice) \(Int(plan.probability * 100))%")
            }
            if context.options.llm {
                // Apple の言語モデル（FoundationModels）に、同じ発話・同じ画面で、次の 1 手を決めさせる。
                let t1 = Date()
                let llm = try LLMPlanner(desktop: ReplayDesktop(snapshot: snapshot, apps: apps))
                let next: LLMPlanner.Next
                do { next = try await llm.next(utterance: utterance, done: []) } catch { print("LLM 失敗: \(error)"); next = .invalid("失敗") }
                llmMillis.append(Date().timeIntervalSince(t1) * 1000)
                var llmGot = "none"
                if case .step(let s) = next { llmGot = PCEval.canonical(s) }
                if !llmTally.record(llmGot: llmGot, against: judgement) { print(Style.red("LLM-MISS") + " \(llmGot) ≠ \(f[1]) [\(f[0])]: \(f[2])  (\(next))") }
            }
        }
        heading("結果（\(tally.total) 文）")
        let w = 14
        if context.options.speak { kv("音声経由", "文字起こしが元の文と違った \(misheard)/\(heard)", width: w) }
        kv("正解", "\(tally.hits)/\(tally.total)  \(pct(Double(tally.hits) / Double(tally.total)))", width: w)
        for (k, v) in tally.byKind.sorted(by: { $0.key < $1.key }) { kv("  " + k, "\(v.hit)/\(v.total)", width: w) }
        let wrong = "\(tally.wrongExecuted) 件" + Style.dim("（確認なしで、違う操作を実行した数）")
        kv("危険な誤り", tally.wrongExecuted > 0 ? Style.red(wrong) : Style.green(wrong), width: w)
        kv("確認なしで実行", "\(tally.positiveExecuted)/\(tally.positives)" + Style.dim("（操作の依頼のうち）"), width: w)
        kv("会話が通った", "\(tally.negativeLeaked)/\(tally.negatives)" + Style.dim("（操作でない発話が、確認か実行へ通った数）"), width: w)
        let time = PCEval.latency(millis)
        kv("時間", String(format: "中央値 %.0f ms・p95 %.0f ms（1 発話）", time.median, time.p95), width: w)
        if context.options.llm {
            let llmTime = PCEval.latency(llmMillis)
            heading("Apple の言語モデル（FoundationModels）")
            kv("正解", "\(llmTally.hits)/\(tally.total)  \(pct(Double(llmTally.hits) / Double(tally.total)))", width: w)
            kv("会話に手を返した", "\(llmTally.negativeLeaked)/\(tally.negatives)", width: w)
            kv("違う手を返した", "\(llmTally.wrongAny)（全体）", width: w)
            kv("併用", "誤って確認なしで実行 \(llmTally.hybridWrongExecuted) 件・確認なしで正しく実行 \(llmTally.hybridPositiveExecuted)/\(tally.positives)" + Style.dim("（Tiny-Jev と一致・ゲート「実行」のときだけ）"), width: w)
            kv("時間", String(format: "中央値 %.0f ms・p95 %.0f ms（1 発話）", llmTime.median, llmTime.p95), width: w)
        }
    }

    /// 文を、合成音声（say）にして、オンデバイスで文字起こしする。
    private func speakAndTranscribe(_ text: String) async throws -> String {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vc-\(UUID().uuidString).aiff")
        // try?: 一時の音声ファイルの片付け。消せなくても、結果は変わらない
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Kyoko", "-o", file.path, text]
        try p.run()
        p.waitUntilExit()
        return try await FileTranscriber().transcribe(file: file)
    }
}

import Foundation
import VCCore
import VCDecision
import VCPCControl
import VCSpeech

func describe(_ plan: Plan) {
    kv("選択", "\(plan.choice)  \(pct(plan.probability))" + Style.dim("（採点 \(plan.rounds) 回）"))
    if let risk = plan.risk { kv("危険度", pct(risk) + Style.dim("（取り消しにくい確率）")) }
    if let step = plan.step { kv("手", step.summary) }
    let verdict: String
    switch plan.verdict {
    case .execute: verdict = Style.green("✓ 実行")
    case .confirm: verdict = Style.yellow("? 確認が要る")
    case .reject: verdict = Style.red("✗ 実行しない")
    }
    kv("判定", verdict + (plan.rejection.map { Style.dim("（\($0)）") } ?? ""))
    if let note = plan.note { notice(note) }
}

/// 文を、合成音声（say）にして、オンデバイスで文字起こしする。
func speakAndTranscribe(_ text: String) async throws -> String {
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

/// 「scroll:down」「window:maximize」「press:cmd+c」「click:名前」「open:アプリ」→ `Step`（eval-context 用）。
func stepFromCanonical(_ s: String, snapshot: Snapshot) -> Step? {
    let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    switch parts[0] {
    case "scroll": return ScrollDirection(rawValue: parts[1]).flatMap { d in snapshot.elements.first(where: \.isScrollable).map { .scroll(d, $0) } }
    case "window": return WindowAction(rawValue: parts[1]).map { .window($0, app: snapshot.app) }
    case "press": return Shortcut.all.first { $0.combo == parts[1] }.map { .press($0) }
    case "click": return snapshot.elements.first { $0.name == parts[1] && $0.canClick }.map { .click($0) }
    case "open": return .openApp(parts[1])
    default: return nil
    }
}

/// 結果を、コーパスの「期待」と同じ形の文字にする。
func canonical(_ plan: Plan) -> String { canonicalStep(plan.step) }

func canonicalStep(_ step: Step?) -> String {
    switch step {
    case nil: return "none"
    case .openApp(let n)?: return "open:" + n
    case .click(let e)?: return "click:" + e.name   // 位置つきの期待（「click:Open@右上」）は、eval が別に比べる
    case .type(let t, _)?: return "type:" + t
    case .press(let s)?: return "press:" + s.combo
    case .scroll(let d, _)?: return "scroll:" + d.rawValue
    case .window(let a, _)?: return "window:" + a.rawValue
    case .search(let q, _)?: return "search:" + q
    case .element(let v, let e)?: return v.rawValue + ":" + e.name
    case .closeApp(let n)?: return "close:" + n
    }
}

/// 発話を、1 手ずつに分ける。既定はルール（`ClauseSplitter`）。`--llm-split` なら、言語モデル（FoundationModels）で書き直す（使えない・失敗のときは、ルール）。
func clauses(for utterance: String, llmSplit: Bool) async -> [String] {
    guard llmSplit else { return ClauseSplitter.split(utterance) }
    do {
        let steps = try await LLMDecomposer().steps(for: utterance)
        if !steps.isEmpty { print("言語モデルで分けた：" + steps.joined(separator: " ／ ")); return steps }
    } catch { print("言語モデルで分けられない（\(error)）。ルールで分ける") }
    return ClauseSplitter.split(utterance)
}

/// 発話を 1 手ずつに分け、順に、計画し、（act かつ --execute なら）実行する。前の手を実行したあとの画面で、次の手を計画する。
/// どれかの手が「実行しない」になれば、残りも中止する。確認が要る手は、`confirm` が true を返したときだけ実行する。
/// 実行しない（plan・--execute なし）ときは、いまの画面で、各手を計画して見せるだけ（前の手の結果は、反映されない）。
func runClauses(_ clauses: [String], planner: Planner, desktop: AgentDesktop, act: Bool, context: CommandContext, hud: HUDSession? = nil, cancel: CancelToken? = nil, confirm: (Plan) async throws -> Bool) async throws {
    for (i, clause) in clauses.enumerated() {
        let more = i + 1 < clauses.count
        heading(clauses.count > 1 ? "[\(i + 1)/\(clauses.count)] \(clause)" : clause)
        if cancel?.isCancelled == true { throw CancellationError() }
        let plan = try planner.plan(clause, history: context.options.noContext ? [] : context.sessionHistory.entries)
        describe(plan)
        guard let step = plan.step, plan.verdict != .reject else {
            print("  " + Style.dim("→ 実行しない" + (more ? "（残りも中止）" : "")))
            hud?.update { $0.steps.append(.init(command: "\(plan.choice)", status: .denied, output: plan.rejection ?? "確信が足りないので、実行しません")) }
            return
        }
        guard act, context.options.execute else {
            if act { print("  " + Style.dim("dry-run：実行していない（--execute で実行）")) }
            hud?.update { $0.steps.append(.init(command: step.summary, status: .denied, output: "実行していません（--execute なし）")) }
            continue
        }
        if plan.verdict == .confirm, !(try await confirm(plan)) {
            print("  " + Style.yellow("やめた（確認が取れない）" + (more ? "。残りも中止" : "")))
            hud?.update { $0.steps.append(.init(command: step.summary, status: .denied, output: "やめました")) }
            return
        }
        hud?.update { $0.steps.append(.init(command: step.summary)) }
        if cancel?.isCancelled == true { throw CancellationError() }
        try desktop.perform(step)
        context.sessionHistory.append(Executed(step: step))
        print("  " + Style.green("✓ done"))
        hud?.update { if let last = $0.steps.indices.last { $0.steps[last].status = .ok } }
        if more { try await Task.sleep(nanoseconds: 800_000_000) }   // 画面が落ち着くのを待つ
    }
}

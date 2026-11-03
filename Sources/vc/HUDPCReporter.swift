import Foundation
import VCPCControl

/// 声の流れでの、PC 操作の出来事（`PCEvent`）を、画面の上の表示（`HUDSession`）と、端末（`TerminalPCReporter`）へ出す。
/// 1 つの発話ごとに作る。`begin()` で「考え中」を出し、`PCRunner.run` が返ったら、`finish()` で結果にする。確認が要るときは、問いかけを読み上げる。
final class HUDPCReporter: PCReporter, @unchecked Sendable {
    private let terminal: TerminalPCReporter
    private let speak: @Sendable (String) -> Void
    private let hud: HUDSession

    /// `chip`：右上のチップ（トリガーの名前）。`utterance`：聞こえた文。`terminal`・`present`・`speak`：出力先（既定は、端末・画面の上の表示・`say`。テストで差し替える）。
    init(chip: String, utterance: String,
         terminal: TerminalPCReporter = TerminalPCReporter(),
         present: @escaping @Sendable (HUDContent, TimeInterval?) -> Void = { HUD.shared.show($0, hideAfter: $1) },
         speak: @escaping @Sendable (String) -> Void = { say($0) }) {
        self.terminal = terminal
        self.speak = speak
        hud = HUDSession(HUDContent(phase: .working, title: "考え中", chip: chip, heard: utterance), present: present)
    }

    func begin() { hud.update() }

    /// 実行した手が 1 つでもあれば「完了」、なければ「実行しませんでした」。
    func finish() {
        hud.update(hideAfter: 3) { content in
            let done = content.steps.contains { if case .ok = $0.status { return true } else { return false } }
            content.phase = done ? .success : .info
            content.title = done ? "完了" : "実行しませんでした"
            content.hint = nil
        }
    }

    func report(_ event: PCEvent) {
        switch event {
        case .llmSplit, .llmSplitFailed, .clause, .planned:
            terminal.report(event)
        case let .rejected(plan, _):
            terminal.report(event)
            hud.update { $0.steps.append(.init(command: "\(plan.choice)", status: .denied, output: plan.rejection ?? "確信が足りないので、実行しません")) }
        case let .planOnly(step), let .dryRun(step):
            terminal.report(event)
            hud.update { $0.steps.append(.init(command: step.summary, status: .denied, output: "実行していません（--execute なし）")) }
        case let .confirmRequired(step):
            speak("\(step.spoken)。実行しますか")
            terminal.out(noticeText("確認待ち：もう一度トリガーを押して「はい」と言う"))
            hud.update { $0.phase = .confirm; $0.title = "実行しますか？"; $0.hint = "\(step.spoken)　もう一度押して「はい」" }
        case .confirmAnswered:
            hud.update { $0.phase = .working; $0.title = "実行中"; $0.hint = nil }
        case let .notConfirmed(step, _):
            terminal.report(event)
            hud.update { $0.steps.append(.init(command: step.summary, status: .denied, output: "やめました")) }
        case let .executing(step):
            hud.update { $0.steps.append(.init(command: step.summary)) }
        case .executed:
            terminal.report(event)
            hud.update { if let last = $0.steps.indices.last { $0.steps[last].status = .ok } }
        }
    }
}

import Foundation
import VCSkill

/// 声の流れでの、スキルの実行の出来事（`RunEvent`）を、画面の上の表示（`HUDSession`）と、端末（声の流れの組み立ての `TerminalReporter`）へ出す。
/// 1 つの発話ごとに作る。確認が要るときは、問いかけを読み上げる。
/// `@unchecked Sendable` の理由：可変な状態（`session`）は、すべて `lock` で守る。ほかの保持物は、不変（`let`）。
final class HUDReporter: RunReporter, @unchecked Sendable {
    private let chip: String
    private let utterance: String
    private let dryRun: Bool
    private let isSuperseded: @Sendable () -> Bool
    private let terminal: TerminalReporter
    private let present: @Sendable (HUDContent, TimeInterval?) -> Void
    private let speak: @Sendable (String) -> Void
    private let document: @Sendable (String) -> String?
    private let image: @Sendable (URL) -> String?
    private let lock = NSLock()
    private var session: HUDSession?
    /// 複数ステップの依頼で、いま何番目か（なければ、ステップに分けていない）。
    private var step: (index: Int, total: Int)?

    /// `chip`：右上のチップ（トリガーの名前）。`utterance`：聞こえた文。`terminal`・`present`・`speak`：出力先（既定は、端末・画面の上の表示・`say`。テストで差し替える）。
    init(chip: String, utterance: String, dryRun: Bool,
         isSuperseded: @escaping @Sendable () -> Bool = { false },
         terminal: TerminalReporter? = nil,
         present: @escaping @Sendable (HUDContent, TimeInterval?) -> Void = { HUD.shared.show($0, hideAfter: $1) },
         speak: @escaping @Sendable (String) -> Void = { say($0) },
         document: @escaping @Sendable (String) -> String? = { DocumentWindow.present(markdown: $0) },
         image: @escaping @Sendable (URL) -> String? = { ImagePanel.present(file: $0, title: "加工した画像") }) {
        self.chip = chip
        self.utterance = utterance
        self.dryRun = dryRun
        self.isSuperseded = isSuperseded
        self.terminal = terminal ?? TerminalReporter(layout: .voice, dryRun: dryRun)
        self.present = present
        self.speak = speak
        self.document = document
        self.image = image
    }

    private var progress: String {
        lock.lock(); defer { lock.unlock() }
        return step.map { "（\($0.index)/\($0.total)）" } ?? ""
    }

    private var workingTitle: String { (dryRun ? "確認のみ（--dry-run）" : "実行中") + progress }

    private func update(hideAfter: TimeInterval? = nil, _ change: (inout HUDContent) -> Void = { _ in }) {
        lock.lock(); let current = session; lock.unlock()
        current?.update(hideAfter: hideAfter, change)
    }

    /// スキルが決まったら、画面の上の表示を、実行中で始める。
    private func begin(_ skill: Skill) {
        let hud = HUDSession(HUDContent(phase: .working, title: workingTitle, chip: chip, heard: utterance, skill: skill.name), present: present)
        lock.lock(); session = hud; lock.unlock()
        hud.update()
    }

    func report(_ event: RunEvent) {
        switch event {
        case .forced(let skill), .matched(let skill, _, _), .fellBack(let skill, _, _, _):
            terminal.report(event)
            begin(skill)
        case let .declined(reason, fallbackAvailable, _):
            terminal.report(event)
            if fallbackAvailable {
                present(HUDContent(phase: .info, title: "操作の依頼ではありませんでした", hint: reason, chip: chip, heard: utterance), 3)
            } else {
                // 当てはまるスキルがなく、既定スキルも使えない：実行しない
                present(HUDContent(phase: .info, title: "どのスキルでもありません", hint: "実行しません（既定スキルが無効：vc skills enable default）", chip: chip, heard: utterance), 3)
            }
        case let .confirmRequired(skill, reason):
            speak("\(skill.name)を実行しますか")
            terminal.report(event)
            update { $0.phase = .confirm; $0.title = "実行しますか？"; $0.choices = true; $0.hint = reason + "。" + ConfirmGuide.howToAnswer }
        case .confirmationDeclined:
            terminal.report(event)
            update(hideAfter: 2.5) { $0.phase = .info; $0.title = "やめました"; $0.hint = nil; $0.choices = false }
        case .confirmed:
            update { [title = workingTitle] in $0.phase = .working; $0.title = title; $0.hint = nil; $0.choices = false }
        case .started:
            break
        case let .command(command):
            terminal.report(event)
            update { $0.steps.append(.init(command: command)) }
        case let .result(code, output):
            terminal.report(event)
            update { content in
                guard let last = content.steps.indices.last else { return }
                content.steps[last].status = code == 0 ? .ok : .failed(code)
                content.steps[last].output = HUDSession.firstLine(output)
            }
        case let .denied(command, reason):
            terminal.report(event)
            update { $0.steps.append(.init(command: command, status: .denied, output: reason)) }
        case let .document(markdown):
            // ウィンドウに表示する結果（HUD には、出さない。端末にも、本文は出さない）
            if let why = document(markdown) { eprint("ウィンドウを出せません: \(why)") }
        case let .image(url):
            if let why = image(url) { eprint("パネルを出せません: \(why)") }
        case let .reply(reply, _, _):
            terminal.report(event)
            lock.lock(); let current = step; lock.unlock()
            let intermediate = current.map { $0.index < $0.total } ?? false   // 途中のステップ：すぐ、次の表示に替わる
            update(hideAfter: intermediate ? 1.5 : HUDSession.readingTime(for: reply)) { [dryRun, progress] in
                if dryRun {
                    // 実行していないので、成功（緑）にしない。言語モデルの返事は、実行したかのように書くことがある。
                    $0.phase = .info
                    $0.title = "実行していません（--dry-run）"
                    $0.reply = "コマンドは実行していません。\n" + reply
                } else {
                    $0.phase = .success
                    $0.title = "完了" + progress
                    $0.reply = reply
                }
            }
        case let .failed(message):
            terminal.report(event)
            update(hideAfter: 7) { $0.phase = .failure; $0.title = "失敗"; $0.choices = false; $0.reply = message }
        case let .planned(steps):
            terminal.report(.planned(steps: steps))
        case let .stepStarted(index, total, _):
            lock.lock(); step = (index, total); lock.unlock()
            terminal.report(event)
        case .carriedResult:
            terminal.report(event)
        case let .planStopped(completed, total):
            terminal.report(event)
            update(hideAfter: 7) { $0.hint = "ステップ \(completed + 1)/\(total) で止まりました（済み：\(completed)）" }
        case .cancelled:
            // 新しい発話に、取って代わられた：「取りやめました」を出さない（新しい発話の表示を、上書きしない）
            if isSuperseded() { return }
            terminal.report(event)
            update(hideAfter: 2) { $0.phase = .info; $0.title = "取りやめました"; $0.hint = nil; $0.reply = nil; $0.choices = false }
        }
    }
}

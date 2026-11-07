import Foundation
import TestSupport
import Testing
import VCSkill
@testable import vc

@Suite struct HUDReporterTests {
    private struct Shown { let content: HUDContent; let hideAfter: TimeInterval? }

    private func reporter(dryRun: Bool = false) -> (reporter: HUDReporter, shown: Collected<Shown>, spoken: Collected<String>, out: Collected<String>) {
        let shown = Collected<Shown>(), spoken = Collected<String>(), out = Collected<String>()
        let terminal = TerminalReporter(layout: .voice, dryRun: dryRun, out: { out.add(plain($0)) }, err: { _ in })
        let reporter = HUDReporter(chip: "shift", utterance: "テスト", dryRun: dryRun, terminal: terminal,
                                   present: { shown.add(Shown(content: $0, hideAfter: $1)) }, speak: { spoken.add($0) })
        return (reporter, shown, spoken, out)
    }

    /// 新しい発話に取って代わられて中断したときは、「取りやめました」を出さない（新しい発話の表示を、上書きしない）。Esc の取りやめは、出す。
    @Test func aSupersededRunShowsNoCancelledPanelButAnEscapeCancelDoes() {
        let shown = Collected<Shown>(), out = Collected<String>()
        let terminal = TerminalReporter(layout: .voice, dryRun: false, out: { out.add(plain($0)) }, err: { _ in })
        let superseded = HUDReporter(chip: "shift", utterance: "テスト", dryRun: false, isSuperseded: { true }, terminal: terminal,
                                     present: { shown.add(Shown(content: $0, hideAfter: $1)) }, speak: { _ in })
        [RunEvent.matched(sample, probability: 0.9, elapsed: 0), .command("open -a Spotify")].forEach(superseded.report)
        let before = shown.values.count
        superseded.report(.cancelled)
        #expect(shown.values.count == before && !out.values.contains { $0.contains("取りやめ") })

        let escaped = reporter()
        [RunEvent.matched(sample, probability: 0.9, elapsed: 0), .cancelled].forEach(escaped.reporter.report)
        #expect(escaped.shown.values.last?.content.title == "取りやめました")
    }

    @Test func aConfirmedRunWalksThroughConfirmWorkingAndSuccess() {
        let r = reporter()
        let events: [RunEvent] = [
            .matched(sample, probability: 0.9, elapsed: 0),
            .confirmRequired(sample, reason: "確信度が高くないので、確認します"),
            .confirmed,
            .started,
            .command("open -a Spotify"),
            .result(exitCode: 0, output: "\n  最初の行  \n二行目"),
            .reply("done: 開いた", commandCount: 1, elapsed: 0.5),
        ]
        events.forEach(r.reporter.report)

        let shown = r.shown.values
        #expect(shown.map(\.content.title) == ["実行中", "実行しますか？", "実行中", "実行中", "実行中", "完了"])
        #expect(shown.map(\.content.phase) == [.working, .confirm, .working, .working, .working, .success])
        #expect(shown[0].content.skill == "default" && shown[0].content.chip == "shift" && shown[0].content.heard == "テスト")
        // 案内の文言は、固定しない（理由が、先頭に付くことだけを確かめる）
        #expect(shown[1].content.hint?.hasPrefix("確信度が高くないので、確認します") == true)
        // ボタン（実行する・やめる）は、確認を待つ間だけ出る（答えたあとは、消える）
        #expect(shown.map(\.content.choices) == [false, true, false, false, false, false])
        #expect(shown[2].content.hint == nil)
        #expect(shown[3].content.steps.map(\.command) == ["open -a Spotify"])
        #expect(String(describing: shown[4].content.steps[0].status) == "ok" && shown[4].content.steps[0].output == "最初の行")
        #expect(shown[5].content.reply == "done: 開いた" && shown[5].hideAfter == HUDSession.readingTime(for: "done: 開いた"))
        #expect(shown.dropLast().allSatisfy { $0.hideAfter == nil })
        #expect(r.spoken.values == ["defaultを実行しますか"])
    }

    @Test func dryRunDoesNotLookLikeSuccess() {
        let r = reporter(dryRun: true)
        [RunEvent.matched(sample, probability: 0.9, elapsed: 0), .started, .reply("done: 開いた", commandCount: 0, elapsed: 0)].forEach(r.reporter.report)
        let shown = r.shown.values
        #expect(shown[0].content.title == "確認のみ（--dry-run）")
        #expect(shown[1].content.phase == .info && shown[1].content.title == "実行していません（--dry-run）")
        #expect(shown[1].content.reply == "コマンドは実行していません。\ndone: 開いた")
    }

    @Test func aDeniedCommandIsAStepWithItsReason() {
        let r = reporter()
        [RunEvent.matched(sample, probability: 0.9, elapsed: 0), .denied(command: "rm -rf /", reason: "許可されていない")].forEach(r.reporter.report)
        let step = r.shown.values[1].content.steps[0]
        #expect(step.command == "rm -rf /" && step.output == "許可されていない" && String(describing: step.status) == "denied")
    }

    @Test func refusedFailedAndCancelledEndWithTheirOwnMessageAndHideTime() {
        let refused = reporter()
        [RunEvent.matched(sample, probability: 0.9, elapsed: 0), .confirmRequired(sample, reason: "理由"), .confirmationDeclined].forEach(refused.reporter.report)
        #expect(refused.shown.values.last?.content.title == "やめました" && refused.shown.values.last?.content.hint == nil && refused.shown.values.last?.hideAfter == 2.5)
        #expect(refused.out.values.last == "  やめた")

        let failed = reporter()
        [RunEvent.matched(sample, probability: 0.9, elapsed: 0), .failed("止まった")].forEach(failed.reporter.report)
        #expect(failed.shown.values.last?.content.phase == .failure && failed.shown.values.last?.content.reply == "止まった" && failed.shown.values.last?.hideAfter == 7)

        let cancelled = reporter()
        [RunEvent.matched(sample, probability: 0.9, elapsed: 0), .command("open -a Spotify"), .cancelled].forEach(cancelled.reporter.report)
        #expect(cancelled.shown.values.last?.content.title == "取りやめました" && cancelled.shown.values.last?.content.reply == nil && cancelled.shown.values.last?.hideAfter == 2)
    }

    @Test func declinedShowsAnInfoPanelWhetherOrNotTheDefaultSkillCouldHaveRun() {
        let conversation = reporter()
        conversation.reporter.report(.declined(reason: "操作の依頼ではない", fallbackAvailable: true, elapsed: 0))
        #expect(conversation.shown.values.count == 1)
        let panel = conversation.shown.values[0]
        #expect(panel.content.phase == .info && panel.content.title == "操作の依頼ではありませんでした" && panel.content.hint == "操作の依頼ではない")
        #expect(panel.content.chip == "shift" && panel.content.heard == "テスト" && panel.hideAfter == 3)

        // 当てはまるスキルがなく、既定スキルも使えない：実行せず、そう示す（ほかの流れへは回さない）
        let noDefault = reporter()
        noDefault.reporter.report(.declined(reason: "どのスキルにも当てはまらない", fallbackAvailable: false, elapsed: 0))
        #expect(noDefault.shown.values.count == 1)
        let none = noDefault.shown.values[0]
        #expect(none.content.phase == .info && none.content.title == "どのスキルでもありません" && none.content.hint == "実行しません（既定スキルが無効：vc skills enable default）")
        #expect(none.content.chip == "shift" && none.content.heard == "テスト" && none.hideAfter == 3)
    }
}

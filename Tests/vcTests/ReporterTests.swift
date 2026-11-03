import Foundation
import Testing
import VCSkill
@testable import vc

/// 端末の色の指定（端末で実行したときだけ付く）を取り除く。
private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }

private final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Value] = []
    func add(_ value: Value) { lock.lock(); all.append(value); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return all }
}

/// 組み込みの既定スキル（`Skill` の初期化子は、`VCSkill` の外から呼べない）。
private let spotify = DefaultSkill.skill

/// 出力を集める `TerminalReporter`（標準出力の行・標準エラーの行）。
private func terminal(_ layout: TerminalReporter.Layout, dryRun: Bool = false) -> (reporter: TerminalReporter, out: Collected<String>, err: Collected<String>) {
    let out = Collected<String>(), err = Collected<String>()
    return (TerminalReporter(layout: layout, dryRun: dryRun, out: { out.add(plain($0)) }, err: { err.add(plain($0)) }), out, err)
}

@Suite struct TerminalReporterTests {
    @Test func commandLayoutShowsHeadingsDescriptionAndSummary() {
        let t = terminal(.command)
        let events: [RunEvent] = [
            .matched(spotify, probability: 0.9, elapsed: 0.34),
            .confirmRequired(spotify, reason: "確信度が高くないので、確認します"),
            .confirmed,
            .started,
            .command("open -a Spotify"),
            .result(exitCode: 0, output: "ok"),
            .reply("done: 開いた", commandCount: 1, elapsed: 1.25),
        ]
        events.forEach(t.reporter.report)
        #expect(t.out.values == [
            "  Tiny-Jev  default   90.0%（0.3 秒）",
            "  説明      どのスキルにも当てはまらない依頼を、agent-desktop と基本のコマンドで実行する（組み込み）",
            "  許可      agent-desktop、open、say、ls、pwd、date",
            "  ! 確信度が高くないので、確認します。",
            "\n▶ 実行",
            "  $ open -a Spotify",
            "    ✓ exit 0",
            "    │ ok",
            "\n▶ 結果",
            "  返事      done: 開いた",
            "  所要      1.2 秒・実行したコマンド 1 件",
        ])
        #expect(t.err.values.isEmpty)
    }

    @Test func dryRunIsShownInTheHeadingAndTheSummary() {
        let t = terminal(.command, dryRun: true)
        [RunEvent.started, .reply("done: ok", commandCount: 0, elapsed: 0)].forEach(t.reporter.report)
        #expect(t.out.values.first == "\n▶ 実行（dry-run：コマンドは実行しない）")
        #expect(t.out.values.last == "  所要      0.0 秒・実行したコマンド 0 件（dry-run）")
    }

    @Test func longOutputIsCutAfterEightLines() {
        let t = terminal(.command)
        t.reporter.report(.result(exitCode: 2, output: (1...10).map { "line\($0)" }.joined(separator: "\n")))
        #expect(t.out.values.count == 1 + 8 + 1)
        #expect(t.out.values.first == "    ✗ exit 2" && t.out.values.last == "    … 他 2 行")
    }

    @Test func fallbackShowsPromptRiskAndTheForcedSkillIsLabelled() {
        let t = terminal(.command)
        t.reporter.report(.fellBack(spotify, probability: 0.5, risk: 0.25, elapsed: 0))
        t.reporter.report(.forced(spotify))
        #expect(t.out.values[0] == "  Tiny-Jev  どのスキルでもない → 既定スキル default（操作の依頼  50.0%・取り消しにくさ  25.0%・0.0 秒）")
        #expect(t.out.values[3] == "  指定      default")
    }

    @Test func commandLayoutDeclinesWithAReasonEvenWithoutADefaultSkillAndFailuresGoToStandardError() {
        let t = terminal(.command)
        t.reporter.report(.declined(reason: "どのスキルにも当てはまらない", fallbackAvailable: false, elapsed: 0))
        t.reporter.report(.failed("モデルが使えない"))
        #expect(t.out.values == ["  Tiny-Jev  （どのスキルでもない）（0.0 秒）", "\n  → 実行しない（どのスキルにも当てはまらない）"])
        #expect(t.err.values == ["エラー: モデルが使えない"])
    }

    @Test func voiceLayoutHasNoHeadingsAndKeepsFailuresOnStandardOutput() {
        let t = terminal(.voice)
        let events: [RunEvent] = [
            .matched(spotify, probability: 0.9, elapsed: 0),
            .confirmRequired(spotify, reason: "理由"),
            .started,
            .failed("止まった"),
            .cancelled,
        ]
        events.forEach(t.reporter.report)
        #expect(t.out.values == [
            "  Tiny-Jev  default   90.0%（0.0 秒）",
            "  許可      agent-desktop、open、say、ls、pwd、date",
            "  ! 確認待ち：もう一度トリガーを押して「はい」と言う（理由）",
            "失敗: 止まった",
            "  取りやめました（Esc）",
        ])
        #expect(t.err.values.isEmpty)
    }

    @Test func voiceLayoutStaysSilentWhenThePCControlFlowTakesOver() {
        let silent = terminal(.voice)
        silent.reporter.report(.declined(reason: "どのスキルにも当てはまらない", fallbackAvailable: false, elapsed: 0))
        #expect(silent.out.values == ["  Tiny-Jev  （どのスキルでもない）（0.0 秒）"])

        let spoken = terminal(.voice)
        spoken.reporter.report(.declined(reason: "会話", fallbackAvailable: true, elapsed: 0))
        #expect(spoken.out.values.last == "  → 実行しない（会話）")
    }
}

@Suite struct HUDReporterTests {
    private struct Shown { let content: HUDContent; let hideAfter: TimeInterval? }

    private func reporter(dryRun: Bool = false) -> (reporter: HUDReporter, shown: Collected<Shown>, spoken: Collected<String>, out: Collected<String>) {
        let shown = Collected<Shown>(), spoken = Collected<String>(), out = Collected<String>()
        let terminal = TerminalReporter(layout: .voice, dryRun: dryRun, out: { out.add(plain($0)) }, err: { _ in })
        let reporter = HUDReporter(chip: "shift", utterance: "テスト", dryRun: dryRun, terminal: terminal,
                                   present: { shown.add(Shown(content: $0, hideAfter: $1)) }, speak: { spoken.add($0) })
        return (reporter, shown, spoken, out)
    }

    @Test func aConfirmedRunWalksThroughConfirmWorkingAndSuccess() {
        let r = reporter()
        let events: [RunEvent] = [
            .matched(spotify, probability: 0.9, elapsed: 0),
            .confirmRequired(spotify, reason: "確信度が高くないので、確認します"),
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
        #expect(shown[1].content.hint == "確信度が高くないので、確認します。もう一度トリガーを押して、「はい」と言う")
        #expect(shown[2].content.hint == nil)
        #expect(shown[3].content.steps.map(\.command) == ["open -a Spotify"])
        #expect(String(describing: shown[4].content.steps[0].status) == "ok" && shown[4].content.steps[0].output == "最初の行")
        #expect(shown[5].content.reply == "done: 開いた" && shown[5].hideAfter == HUDSession.readingTime(for: "done: 開いた"))
        #expect(shown.dropLast().allSatisfy { $0.hideAfter == nil })
        #expect(r.spoken.values == ["defaultを実行しますか"])
    }

    @Test func dryRunDoesNotLookLikeSuccess() {
        let r = reporter(dryRun: true)
        [RunEvent.matched(spotify, probability: 0.9, elapsed: 0), .started, .reply("done: 開いた", commandCount: 0, elapsed: 0)].forEach(r.reporter.report)
        let shown = r.shown.values
        #expect(shown[0].content.title == "確認のみ（--dry-run）")
        #expect(shown[1].content.phase == .info && shown[1].content.title == "実行していません（--dry-run）")
        #expect(shown[1].content.reply == "コマンドは実行していません。\ndone: 開いた")
    }

    @Test func aDeniedCommandIsAStepWithItsReason() {
        let r = reporter()
        [RunEvent.matched(spotify, probability: 0.9, elapsed: 0), .denied(command: "rm -rf /", reason: "許可されていない")].forEach(r.reporter.report)
        let step = r.shown.values[1].content.steps[0]
        #expect(step.command == "rm -rf /" && step.output == "許可されていない" && String(describing: step.status) == "denied")
    }

    @Test func refusedFailedAndCancelledEndWithTheirOwnMessageAndHideTime() {
        let refused = reporter()
        [RunEvent.matched(spotify, probability: 0.9, elapsed: 0), .confirmRequired(spotify, reason: "理由"), .confirmationDeclined].forEach(refused.reporter.report)
        #expect(refused.shown.values.last?.content.title == "やめました" && refused.shown.values.last?.content.hint == nil && refused.shown.values.last?.hideAfter == 2.5)
        #expect(refused.out.values.last == "  やめた")

        let failed = reporter()
        [RunEvent.matched(spotify, probability: 0.9, elapsed: 0), .failed("止まった")].forEach(failed.reporter.report)
        #expect(failed.shown.values.last?.content.phase == .failure && failed.shown.values.last?.content.reply == "止まった" && failed.shown.values.last?.hideAfter == 7)

        let cancelled = reporter()
        [RunEvent.matched(spotify, probability: 0.9, elapsed: 0), .reply("途中", commandCount: 0, elapsed: 0), .cancelled].forEach(cancelled.reporter.report)
        #expect(cancelled.shown.values.last?.content.title == "取りやめました" && cancelled.shown.values.last?.content.reply == nil && cancelled.shown.values.last?.hideAfter == 2)
    }

    @Test func declinedShowsAnInfoPanelOnlyWhenTheDefaultSkillCouldHaveRun() {
        let conversation = reporter()
        conversation.reporter.report(.declined(reason: "操作の依頼ではない", fallbackAvailable: true, elapsed: 0))
        #expect(conversation.shown.values.count == 1)
        let panel = conversation.shown.values[0]
        #expect(panel.content.phase == .info && panel.content.title == "操作の依頼ではありませんでした" && panel.content.hint == "操作の依頼ではない")
        #expect(panel.content.chip == "shift" && panel.content.heard == "テスト" && panel.hideAfter == 3)

        let handedOver = reporter()
        handedOver.reporter.report(.declined(reason: "どのスキルにも当てはまらない", fallbackAvailable: false, elapsed: 0))
        #expect(handedOver.shown.values.isEmpty)
    }
}

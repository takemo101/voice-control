import Foundation
import TestSupport
import Testing
import VCSkill
@testable import vc

/// 出力を集める `TerminalReporter`（標準出力の行・標準エラーの行）。
private func terminal(_ layout: TerminalReporter.Layout, dryRun: Bool = false) -> (reporter: TerminalReporter, out: Collected<String>, err: Collected<String>) {
    let out = Collected<String>(), err = Collected<String>()
    return (TerminalReporter(layout: layout, dryRun: dryRun, out: { out.add(plain($0)) }, err: { err.add(plain($0)) }), out, err)
}

@Suite struct TerminalReporterTests {
    @Test func commandLayoutAddsHeadingsAndTheDescriptionAndKeepsTheFlowOrder() {
        let t = terminal(.command)
        let events: [RunEvent] = [
            .matched(sample, probability: 0.9, elapsed: 0.34),
            .confirmRequired(sample, reason: "確信度が高くないので、確認します"),
            .started,
            .command("open -a Spotify"),
            .result(exitCode: 0, output: "ok"),
            .reply("done: 開いた", commandCount: 1, elapsed: 1.25),
        ]
        events.forEach(t.reporter.report)
        let lines = t.out.values
        // 見出しは、実行と結果の前に付き、説明は、選んだ行の直後に出る
        #expect(lines.firstIndex { $0.hasSuffix("▶ 実行") }! < lines.firstIndex { $0.hasSuffix("▶ 結果") }!)
        #expect(lines.contains { $0.hasPrefix("  説明") })
        #expect(lines.contains("  ! 確信度が高くないので、確認します。"))
        #expect(lines.contains("    ✓ exit 0") && lines.last!.hasSuffix("実行したコマンド 1 件"))
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
            .matched(sample, probability: 0.9, elapsed: 0),
            .confirmRequired(sample, reason: "理由"),
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

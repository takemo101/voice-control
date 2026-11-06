import Foundation
import Testing
@testable import VCSkill

/// スキルの `timeout`：コマンド 1 つの実行時間の上限（秒）。書かなければ 30 秒。範囲外・数でないものは、読み込みの失敗。
@Suite struct SkillTimeoutTests {
    private func parse(_ extra: String) -> Result<Skill, SkillStore.ParseError> {
        SkillStore.parse("---\nname: demo\ndescription: x\nallowed-commands: sleep\n\(extra)---\nbody", directoryName: "demo", file: URL(fileURLWithPath: "/tmp/demo/SKILL.md"))
    }

    /// 何も書かなければ、30 秒（今までのスキルは、変わらない）。
    @Test func withoutTheFieldTheLimitIsThirtySeconds() throws {
        #expect(try parse("").get().commandTimeout == 30)
    }

    @Test func theFieldSetsTheLimitAndTheEdgesOfTheRangeAreAccepted() throws {
        #expect(try parse("timeout: 120\n").get().commandTimeout == 120)
        #expect(try parse("timeout: 1\n").get().commandTimeout == 1)
        #expect(try parse("timeout: 600\n").get().commandTimeout == 600)
    }

    /// 範囲外・数でない・小数・単位つき：書き間違いを、黙って既定にせず、読み込みの失敗にする（理由に、書ける範囲を示す）。
    @Test func outOfRangeOrNonIntegerValuesFailToLoad() {
        for bad in ["0", "601", "-5", "abc", "1.5", "30s", "9999999999999999999"] {
            guard case let .failure(error) = parse("timeout: \(bad)\n") else { Issue.record("読み込めてしまった：\(bad)"); continue }
            #expect(error.reason.contains("1〜600"), "\(bad)")
        }
    }

    /// 上限は、実際に、コマンドの実行に効く：1 秒のスキルは、3 秒かかるコマンドを、止める（既定の 30 秒なら、止まらない）。
    @Test func theLimitStopsALongCommand() throws {
        let skill = try parse("timeout: 1\n").get()
        let display = ExecutionDisplay(onCommand: { _ in }, onResult: { _, _ in }, onDenied: { _, _ in })
        let session = CommandSession(skill: skill, dryRun: false, display: display, cancel: nil)
        session.begin(request: "x")
        let started = Date()
        let reply = session.execute("sleep 3")
        #expect(reply.contains("timed out after 1 s"))
        #expect(Date().timeIntervalSince(started) < 2.5)
    }
}

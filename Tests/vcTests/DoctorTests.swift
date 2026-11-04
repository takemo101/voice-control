import Testing
import VCSkill
import VCSpeech
@testable import vc

@Suite struct DoctorTests {
    private func plain(_ lines: [String]) -> String { lines.map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }.joined(separator: "\n") }

    /// 必須（Apple Intelligence・Tiny-Jev）が使えなければ失敗（終了コード 1）。任意の機能だけなら、失敗にしない。
    @Test func onlyARequiredItemMakesTheCommandFail() {
        let ok = DoctorCheck.ok("A", "ok")
        let warn = DoctorCheck.warn("B", "no", fix: "do this")
        let fail = DoctorCheck.fail("C", "no", fix: "do that")
        #expect(DoctorReport(checks: [ok, warn]).hasFailure == false)
        #expect(DoctorReport(checks: [ok, warn, fail]).hasFailure == true)
        #expect(DoctorReport(checks: [fail]).failures.count == 1)
    }

    /// 使えない項目の下に、直す手順が出る。使える項目には、出ない。
    @Test func aFixIsShownOnlyUnderAnItemThatDoesNotWork() {
        let text = plain(DoctorReport(checks: [.ok("A", "fine"), .fail("B", "broken", fix: "run the fix")]).lines())
        #expect(text.contains("→ run the fix"))
        #expect(text.components(separatedBy: "→").count == 2)
    }

    @Test func theSummaryTellsWhetherSkillsCanRun() {
        #expect(plain(DoctorReport(checks: [.ok("A", "x")]).lines()).contains("すべて使えます"))
        #expect(plain(DoctorReport(checks: [.ok("A", "x"), .warn("B", "x", fix: "y")]).lines()).contains("スキルの実行（vc run）は使えます"))
        #expect(plain(DoctorReport(checks: [.fail("A", "x", fix: "y")]).lines()).contains("使えません"))
    }

    /// Apple Intelligence が使えない理由は、そのまま、直す手順つきの必須項目の失敗になる。
    @Test func anUnavailableAppleIntelligenceIsARequiredFailureWithItsRemedy() {
        let check = DoctorCommand.appleIntelligenceCheck(.unavailable(.notEnabled))
        #expect(check.state == .fail)
        #expect(check.fix == AppleIntelligence.Reason.notEnabled.remedy)
        #expect(DoctorCommand.appleIntelligenceCheck(.available).state == .ok)
    }

    /// マイクの許可は、任意の機能（声の入力）に要るだけ：未決・拒否でも、失敗にはしない。
    @Test func microphonePermissionNeverFailsTheCommand() {
        #expect(DoctorCommand.microphoneCheck(.granted).state == .ok)
        #expect(DoctorCommand.microphoneCheck(.notDetermined).state == .warn)
        #expect(DoctorCommand.microphoneCheck(.denied).state == .warn)
    }
}

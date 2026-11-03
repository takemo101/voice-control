import Foundation
import Testing
import VCCore
import VCSkill

/// 取りやめたときの外部コマンドの後始末（`CommandRunner`）。取りやめの合図そのものは `VCCore`、録音を捨てる側は `VCSpeech` のテスト（同じ名前のスイート）。
@Suite struct CancellationTests {
    @Test func cancelStopsARunningCommandQuickly() async throws {
        let token = CancelToken()
        let started = Date()
        let canceller = Task { try await Task.sleep(nanoseconds: 300_000_000); token.cancel() }
        let result = await Task.detached { CommandRunner.run(argv: ["sleep", "20"], timeout: 30, cancel: token) }.value
        _ = try await canceller.value
        #expect(result.exitCode == 130 && !result.timedOut)
        #expect(Date().timeIntervalSince(started) < 5)   // 20 秒は待たない
    }

    @Test func aCancelledTokenPreventsTheCommandFromStarting() {
        let token = CancelToken()
        token.cancel()
        let result = CommandRunner.run(argv: ["echo", "should-not-run"], cancel: token)
        #expect(result.exitCode == 130 && !result.output.contains("should-not-run"))
    }
}

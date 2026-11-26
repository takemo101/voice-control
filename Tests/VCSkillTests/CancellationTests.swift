import Foundation
import Testing
import VCCore
import VCSkill

/// 取りやめたときの外部コマンドの後始末（`CommandRunner`）。取りやめの合図そのものは `VCCore`、録音を捨てる側は `VCSpeech` のテスト（同じ名前のスイート）。
@Suite struct CancellationTests {
    @Test func cancelStopsARunningCommandQuickly() async {
        let token = CancelToken()
        let started = Date()
        // 待つ処理と取りやめは、**専用のスレッド**で行う：GCD の共有のスレッドは、CI が、全テストを同じプロセスで動かすと、ほかのテストに塞がれて、取りやめの合図が、10 秒以上遅れた（実測：13.6 秒）。測りたいのは、取りやめの後始末の速さ
        Thread.detachNewThread { Thread.sleep(forTimeInterval: 0.3); token.cancel() }
        let result = await withCheckedContinuation { (c: CheckedContinuation<CommandResult, Never>) in
            Thread.detachNewThread { c.resume(returning: CommandRunner.run(argv: ["sleep", "20"], timeout: 30, cancel: token)) }
        }
        #expect(result.exitCode == 130 && !result.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)   // 20 秒は待たない
    }

    @Test func aCancelledTokenPreventsTheCommandFromStarting() {
        let token = CancelToken()
        token.cancel()
        let result = CommandRunner.run(argv: ["echo", "should-not-run"], cancel: token)
        #expect(result.exitCode == 130 && !result.output.contains("should-not-run"))
    }
}

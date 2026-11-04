import Foundation
import Testing
import VCCore

/// 外部コマンドの実行（`ProcessRunner`）。シェルは使わず、`env` で探せる、決まったコマンドだけで確かめる。
@Suite struct ProcessRunnerTests {
    @Test func passesArgumentsAsIsAndReadsUTF8() {
        // シェルなし：`;` や空白は、ただの文字として、1 つの引数に入る
        let r = ProcessRunner.run(executable: "printf", arguments: ["%s|%s", "a b; echo x", "日本語"], mergeStderr: true, timeout: 10)
        #expect(r.text == "a b; echo x|日本語")
        #expect(r.exitCode == 0 && !r.timedOut && !r.cancelled && r.launchError == nil)
    }

    @Test func returnsTheExitCodeOfTheCommand() {
        let r = ProcessRunner.run(executable: "false", mergeStderr: true, timeout: 10)
        #expect(r.exitCode == 1 && r.output.isEmpty && !r.timedOut)
    }

    @Test func outputFarLargerThanThePipeBufferDoesNotBlock() {
        // パイプの 64 KiB を、大きく超える 1 MiB。終わりまで読みながら待たないと、コマンドが書き込みで止まり、終わらない
        let r = ProcessRunner.run(executable: "jot", arguments: ["-b", "x", "524288"], mergeStderr: true, timeout: 30)
        #expect(!r.timedOut && r.exitCode == 0)
        #expect(r.output.count == 1_048_576)   // "x\n" × 524288
    }

    @Test func aCommandThatRunsTooLongIsStoppedAtTheTimeout() {
        let started = Date()
        let r = ProcessRunner.run(executable: "sleep", arguments: ["5"], mergeStderr: true, timeout: 0.3)
        #expect(r.timedOut && !r.cancelled)
        #expect(r.exitCode == SIGTERM)   // `terminate` で止めた：シグナルの番号
        #expect(Date().timeIntervalSince(started) < 3)   // 5 秒は待たない
    }

    @Test func noTimeoutLetsASlowCommandFinish() {
        let r = ProcessRunner.run(executable: "sleep", arguments: ["0.5"], mergeStderr: true, timeout: nil)
        #expect(r.exitCode == 0 && !r.timedOut && !r.cancelled)
    }

    @Test func cancellingStopsARunningCommandPromptly() async {
        let token = CancelToken()
        let started = Date()
        // 待つ処理と取りやめは、GCD で行う：Swift の並行処理のスレッドを、塞がない（CI は、全テストを同じプロセスで動かし、スレッドが足りなくなると、取りやめが遅れる）
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        let r = await withCheckedContinuation { (c: CheckedContinuation<ProcessResult, Never>) in
            DispatchQueue.global().async { c.resume(returning: ProcessRunner.run(executable: "sleep", arguments: ["5"], mergeStderr: true, timeout: 30, cancel: token)) }
        }
        #expect(r.cancelled && !r.timedOut && r.exitCode == 130)
        #expect(Date().timeIntervalSince(started) < 4)   // 5 秒は待たない
    }

    @Test func aCancelledTokenPreventsTheCommandFromStarting() {
        let token = CancelToken()
        token.cancel()
        let r = ProcessRunner.run(executable: "echo", arguments: ["should-not-run"], mergeStderr: true, timeout: 10, cancel: token)
        #expect(r.cancelled && r.exitCode == 130 && r.output.isEmpty)
    }

    @Test func aMissingCommandEndsWith127() {
        // env が「見つからない」と報告して、127 で終わる（起動の失敗ではない）
        let merged = ProcessRunner.run(executable: "vc-no-such-command", mergeStderr: true, timeout: 10)
        #expect(merged.exitCode == 127 && merged.launchError == nil && !merged.cancelled)
        #expect(merged.text.contains("vc-no-such-command"))
        let discarded = ProcessRunner.run(executable: "vc-no-such-command", mergeStderr: false, timeout: 10)
        #expect(discarded.exitCode == 127 && discarded.output.isEmpty)
    }

    @Test func standardErrorIsMergedOrDiscardedAsAsked() {
        // `-d /` は標準出力へ `/`、存在しない場所は標準エラーへメッセージ
        let arguments = ["-d", "/", "/vc-no-such-path"]
        let merged = ProcessRunner.run(executable: "ls", arguments: arguments, mergeStderr: true, timeout: 10)
        #expect(merged.exitCode == 1)
        #expect(merged.text.contains("/\n") && merged.text.contains("vc-no-such-path"))
        let discarded = ProcessRunner.run(executable: "ls", arguments: arguments, mergeStderr: false, timeout: 10)
        #expect(discarded.exitCode == 1)
        #expect(discarded.text == "/\n")
    }

    @Test func standardInputIsEmptyByDefault() {
        // 標準入力が、端末や開いたままのパイプだと、`cat` は入力の終わりを待ち続ける。空（/dev/null）なら、すぐ終わる
        // （限界：テストを動かす側の標準入力が /dev/null のときは、この確認では、/dev/null への差し替えの有無を区別できない）
        let r = ProcessRunner.run(executable: "cat", mergeStderr: true, timeout: 10)
        #expect(r.exitCode == 0 && r.output.isEmpty && !r.timedOut)
    }
}

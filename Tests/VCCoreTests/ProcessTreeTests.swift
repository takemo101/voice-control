import Darwin
import Foundation
import Testing
import TestSupport
import VCCore

/// **子プロセスごと止める**：コマンドやエージェントを止めたとき、それが起こした子孫が、残って動き続けない。
/// 実測（修正前）：同じグループの孫は、止まるが、**自分のセッションへ外れた孫**（`detached`・`setsid`）は、止めたあとも、生きていた。
/// 孫は、`sleep 30x`（残れば、5 分、生きている）。**後始末で、必ず、止める**。
@Suite struct ProcessTreeTests {
    @Test func aCommandThatTimesOutTakesItsDetachedGrandchildWithIt() throws {
        let directory = try ProcessProbe.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let result = ProcessRunner.run(executable: "sh", arguments: ["-c", ProcessProbe.detachedGrandchildScript(pidFile: pidFile, seconds: 306)], mergeStderr: true, timeout: 1.0)
        let pid = try #require(ProcessProbe.readPid(pidFile))
        defer { kill(pid, SIGKILL) }
        #expect(result.timedOut)
        #expect(ProcessProbe.waitUntilDead(pid), "外れた孫が、残った（pid \(pid)）")
    }

    @Test func cancellingACommandTakesItsDetachedGrandchildWithIt() async throws {
        let directory = try ProcessProbe.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let token = CancelToken()
        let runner = Thread {
            _ = ProcessRunner.run(executable: "sh", arguments: ["-c", ProcessProbe.detachedGrandchildScript(pidFile: pidFile, seconds: 307)], mergeStderr: true, timeout: 30, cancel: token)
        }
        runner.start()
        let pid = try #require(ProcessProbe.readPid(pidFile))
        defer { kill(pid, SIGKILL) }
        token.cancel()
        #expect(ProcessProbe.waitUntilDead(pid), "外れた孫が、残った（pid \(pid)）")
    }

    @Test func aGrandchildThatIgnoresTermIsKilledAfterTheGrace() throws {
        let directory = try ProcessProbe.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ProcessProbe.detachedGrandchildScript(pidFile: pidFile, seconds: 308, ignoreTerm: true)]
        try process.run()
        let pid = try #require(ProcessProbe.readPid(pidFile))
        defer { kill(pid, SIGKILL); if process.isRunning { process.terminate() } }
        ProcessTree.terminate(process, grace: 0.3)
        Thread.sleep(forTimeInterval: 0.15)
        #expect(ProcessProbe.isAlive(pid), "SIGTERM は、無視される（この時点では、生きている）")
        #expect(ProcessProbe.waitUntilDead(pid), "猶予のあとの SIGKILL で、止まる（pid \(pid)）")
    }

    @Test func descendantsAreFoundRecursivelyAndNothingUnrelatedIsTouched() throws {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["309"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        let tree = Process()
        tree.executableURL = URL(fileURLWithPath: "/bin/sh")
        tree.arguments = ["-c", "(sleep 310 & wait) & wait"]            // sh → 副シェル → sleep（孫の、その先まで）
        try tree.run()
        defer { if tree.isRunning { tree.terminate() } }
        var found: [pid_t] = []
        for _ in 0..<100 {
            found = ProcessTree.descendants(of: tree.processIdentifier)
            if found.count >= 2 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(found.count >= 2 && !found.contains(tree.processIdentifier) && !found.contains(unrelated.processIdentifier))
        ProcessTree.terminate(tree, grace: 0.3)
        #expect(found.allSatisfy { ProcessProbe.waitUntilDead($0) })
        #expect(unrelated.isRunning)                                     // 関係のないプロセスは、止めない
    }
}

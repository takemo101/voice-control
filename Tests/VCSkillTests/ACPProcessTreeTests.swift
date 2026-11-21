import Foundation
import Testing
import TestSupport
import VCCore
@testable import VCSkill

/// ACP のエージェントを閉じたとき、そのエージェントが起こした子孫が、残らない（エージェントは、`bash`・`osascript` などを起こす：残ると、取りやめたあとも、画面の操作を続ける）。
/// 実測（修正前）：自分のセッションへ外れた孫（node の `detached: true` と同じ）は、`close` のあとも、生きていた。
@Suite struct ACPProcessTreeTests {
    @Test func closingTheConnectionTakesTheAgentsDetachedChildWithIt() throws {
        let directory = try ProcessProbe.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let connection = ACPConnection(argv: ["sh", "-c", ProcessProbe.detachedGrandchildScript(pidFile: pidFile, seconds: 311)], directory: directory)
        try connection.start()
        let child = try #require(ProcessProbe.readPid(pidFile))
        defer { kill(child, SIGKILL) }
        #expect(connection.isAlive)
        connection.close()
        #expect(ProcessProbe.waitUntilDead(child), "外れた孫が、残った（pid \(child)）")
    }

    @Test func closingTheConnectionTakesAnOrdinaryChildWithIt() throws {
        let directory = try ProcessProbe.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let connection = ACPConnection(argv: ["sh", "-c", "sleep 312 & echo $! > \(pidFile.path); wait"], directory: directory)
        try connection.start()
        let child = try #require(ProcessProbe.readPid(pidFile))
        defer { kill(child, SIGKILL) }
        connection.close()
        #expect(ProcessProbe.waitUntilDead(child), "孫が、残った（pid \(child)）")
    }
}

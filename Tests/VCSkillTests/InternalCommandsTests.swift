import Foundation
import Testing
import VCDecision
@testable import VCSkill

/// スキルの中の `vc find`・`vc pick`：許可の照合を通ったときだけ、`vc` 自身が処理する（外のプロセスを起こさない）。候補は、同じ実行の中だけ覚える。
@Suite struct InternalCommandsTests {
    /// 最初の候補に高い確率を返す偽物（候補の分 + 「どれでもない」）。
    private struct FirstWins: OptionScorer {
        func score(state: String, question: String, options: [String]) throws -> [Double] {
            var p = Array(repeating: 0.02, count: options.count); p[0] = 0.9; return p
        }
    }

    private static let firstWins: @Sendable () -> OptionScorer? = { FirstWins() as OptionScorer }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func session(_ allowed: [String], scorer: Bool = true, dryRun: Bool = false, files: [String] = []) -> (CommandSession, Log) {
        let log = Log()
        let display = ExecutionDisplay(onCommand: { log.add("command \($0)") }, onResult: { code, _ in log.add("result \(code)") }, onDenied: { cmd, _ in log.add("denied \(cmd)") })
        let skill = Skill(name: "files", description: "x", allowedCommands: allowed, confirm: false, body: "x", file: URL(fileURLWithPath: "/tmp/files/SKILL.md"))
        let s: CommandSession
        if scorer { s = CommandSession(skill: skill, dryRun: dryRun, display: display, cancel: nil, scorer: Self.firstWins) }
        else { s = CommandSession(skill: skill, dryRun: dryRun, display: display, cancel: nil, scorer: nil) }
        s.spotlight = { _, _ in files }
        s.begin(request: "先月の請求書を開いて")
        return (s, log)
    }

    private func makeFiles() throws -> (dir: String, paths: [String]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let paths = try ["請求書_10月.pdf", "請求書_9月.pdf", "見積書.pdf"].map { name -> String in
            let url = dir.appendingPathComponent(name); try "x".write(to: url, atomically: true, encoding: .utf8); return url.path
        }
        return (dir.path, paths)
    }

    @Test func findListsCandidatesWithPathsAndPickChoosesAmongThemUsingTheRequest() throws {
        let (dir, paths) = try makeFiles()
        let (s, log) = session(["vc find", "vc pick"], files: Array(paths.prefix(2)))   // Spotlight の偽物は、問い合わせに合うもの（請求書の 2 つ）だけを返す
        let found = s.execute("vc find --name 請求書 --in \(dir)")
        #expect(found.hasPrefix("exit 0\nfound 2 file(s):") && found.contains("請求書_10月.pdf") && found.contains(paths[0]) && !found.contains("見積書"))
        let picked = s.execute("vc pick")
        #expect(picked.hasPrefix("exit 0\nverdict: picked\n") && picked.contains("paths:\n1) "))
        #expect(log.all.filter { $0.hasPrefix("result") } == ["result 0", "result 0"])
    }

    /// 許可にない `vc find` は、実行しない（`allowed-commands` が、実行の上限）。
    @Test func anUnlistedInternalCommandIsDenied() {
        let (s, log) = session(["vc pick"])
        #expect(s.execute("vc find --name a").hasPrefix("ERROR: not allowed"))
        #expect(log.all == ["denied vc find --name a"])
    }

    @Test func pickNeedsOptionsAndTinyJev() {
        let (a, _) = session(["vc pick"])
        #expect(a.execute("vc pick").contains("no options"))
        let (b, _) = session(["vc pick"], scorer: false)
        #expect(b.execute("vc pick --option a --option b").contains("Tiny-Jev is not available"))
        let (c, _) = session(["vc pick"])
        #expect(c.execute("vc pick --option a --option b --query 例").hasPrefix("exit 0\nverdict: picked\na"))
        #expect(c.execute("vc pick --threshold 2 --option a").contains("error:") && c.execute("vc pick --bogus").contains("unknown option"))
    }

    /// 直前のコマンドの出力の行も、選べる（`vc find` に限らない：汎用）。
    @Test func pickCanChooseAmongTheLinesOfThePreviousCommand() {
        let (s, _) = session(["printf", "vc pick"])
        _ = s.execute("printf 'りんご\\nみかん\\nぶどう\\n'")
        #expect(s.execute("vc pick --query みかん").hasPrefix("exit 0\nverdict: picked\nりんご"))   // 偽物は、最初を選ぶ
    }

    @Test func badFindArgumentsReturnAnErrorAndADryRunRunsNothing() {
        let (s, _) = session(["vc find"])
        #expect(s.execute("vc find").contains("--name・--ext・--since のどれかが要ります"))
        #expect(s.execute("vc find --name a --in /no/such").hasPrefix("exit 2"))
        let (d, log) = session(["vc find"], dryRun: true)
        #expect(d.execute("vc find --name a").hasPrefix("(dry-run)"))
        #expect(log.all == ["command vc find --name a"])
    }
}

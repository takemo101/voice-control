import Darwin
import Foundation
import VCCore

/// 子プロセスの後始末を確かめるテストの道具（子孫の番号・生死・外れた孫を起こす `sh` の引数）。VCCore・VCSkill の、どちらのテストも使う。
public enum ProcessProbe {
    /// 生きているか（ゾンビは、死んだものとして数える：親が、まだ、待っていないだけ）。
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        let state = ProcessRunner.run(executable: "ps", arguments: ["-o", "stat=", "-p", "\(pid)"], mergeStderr: true, timeout: 5).text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !state.isEmpty && !state.hasPrefix("Z")
    }

    /// 失敗したとき、状態を、メッセージに出す（CI で、止め損ねた原因を、つかむため）。
    public static func describe(_ pid: pid_t) -> String {
        ProcessRunner.run(executable: "ps", arguments: ["-o", "pid=,ppid=,stat=,comm=", "-p", "\(pid)"], mergeStderr: true, timeout: 5).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func waitUntilDead(_ pid: pid_t, seconds: Double = 5) -> Bool {
        let limit = Date().addingTimeInterval(seconds)
        while Date() < limit { if !isAlive(pid) { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return !isAlive(pid)
    }

    /// 自分のセッションへ外れた孫を起こして、その番号をファイルに書く `sh` の、引数。`ignoreTerm`：SIGTERM を無視する孫。
    public static func detachedGrandchildScript(pidFile: URL, seconds: Int, ignoreTerm: Bool = false) -> String {
        let ignore = ignoreTerm ? "$SIG{TERM}=\"IGNORE\"; " : ""
        return "perl -e 'use POSIX; POSIX::setsid(); \(ignore)open(F, \">\", $ARGV[0]); print F $$; close F; exec \"sleep\", \"\(seconds)\"' \(pidFile.path) & wait"
    }

    /// 孫の番号を、読む。**孫が、`sleep` に、化けるまで（`exec` が終わるまで）待つ**：番号は、`exec` の前に、書かれる。`exec` の最中は、`proc_pidinfo` が、起動時刻を返せず、`ProcessTree` が、その孫を、一覧から落とす（CI で、時々、止め損ねた：2 回）。
    public static func readPid(_ file: URL, seconds: Double = 5) -> pid_t? {
        let limit = Date().addingTimeInterval(seconds)
        while Date() < limit {
            if let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                while Date() < limit {
                    let name = ProcessRunner.run(executable: "ps", arguments: ["-o", "comm=", "-p", "\(pid)"], mergeStderr: true, timeout: 5).text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if name.hasSuffix("sleep") { return pid }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                return pid
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    public static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vc-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

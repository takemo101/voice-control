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

    public static func readPid(_ file: URL, seconds: Double = 5) -> pid_t? {
        let limit = Date().addingTimeInterval(seconds)
        while Date() < limit {
            if let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
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

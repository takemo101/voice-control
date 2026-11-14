import Darwin
import Foundation

/// いま `vc` を動かしている**端末アプリ**（Terminal・iTerm・Ghostty・VS Code など）。
/// マイクなどの許可は、`vc` 自身ではなく、**親をたどった先のアプリ（macOS の言う「責任のあるプロセス」）**に付く。許可したはずなのに「許可されていません」と出るときは、別の端末アプリで動かしている・許可が古い、のことが多いので、**どのアプリの許可が要るか**を、メッセージに出す。
public struct HostApp: Equatable, Sendable {
    /// 例：`Ghostty`。
    public let name: String
    /// 例：`com.mitchellh.ghostty`。`tccutil reset Microphone <この値>` で、そのアプリの許可だけを、やり直せる。
    public let bundleIdentifier: String?

    /// 親のプロセスの実行ファイルのパス（近い順）から、最初の `.app` を探す（**純粋**：テストできる）。
    static func find(in executablePaths: [String]) -> (name: String, bundlePath: String)? {
        for path in executablePaths {
            // 入れ子の .app（Helper など）でも、いちばん外の .app を取る
            guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else { continue }
            let bundlePath = String(path[..<range.upperBound]).hasSuffix("/") ? String(path[..<range.upperBound].dropLast()) : String(path[..<range.upperBound])
            let name = String((bundlePath as NSString).lastPathComponent.dropLast(".app".count))
            return (name, bundlePath)
        }
        return nil
    }

    /// このプロセスの親をたどって、最初の `.app` を返す。見つからなければ `nil`（`ssh`・常駐の `tmux` の中など）。
    public static func current() -> HostApp? {
        var paths: [String] = []
        var pid = getppid()
        var steps = 0
        while pid > 1, steps < 32 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { paths.append(String(cString: buffer)) }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
            pid = pid_t(info.pbi_ppid)
            steps += 1
        }
        guard let found = find(in: paths) else { return nil }
        return HostApp(name: found.name, bundleIdentifier: Bundle(path: found.bundlePath)?.bundleIdentifier)
    }
}

import Darwin
import Foundation

/// いま `vc` を動かしている**アプリ**の候補（Terminal・iTerm・Ghostty・VS Code・Tern など）。
/// マイクなどの許可は、`vc` 自身ではなく、**親をたどった先のアプリ（macOS の言う「責任のあるプロセス」）**に付く。許可したはずなのに「許可されていません」と出るときは、**許可を付けたアプリと、実際に責任を持つアプリが違う**ことが多い。
/// 実例：Tern は、シェルを、本体（`Tern.app`）ではなく、**ヘルパー（`Tern Daemon.app`。bundle id が別）**から起動する。設定で本体をオンにしても、ヘルパーの許可は、別。
/// そのため、親のパスにある `.app` を、**内側（実際に動いているもの）から外側の順に、すべて**候補として出す。
public struct HostApp: Equatable, Sendable {
    /// 例：`Tern Daemon`。
    public let name: String
    /// 例：`so.stencil.tern.daemon`。`tccutil reset Microphone <この値>` で、そのアプリの許可だけを、やり直せる。
    public let bundleIdentifier: String?

    /// 親のプロセスの実行ファイルのパス（近い順）から、`.app` を、内側から外側の順に、重複なしで集める（**純粋**：テストできる）。
    static func bundlePaths(in executablePaths: [String]) -> [String] {
        var result: [String] = []
        for path in executablePaths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            var prefix = ""
            var found: [String] = []
            for part in parts {
                prefix += "/" + part
                if part.hasSuffix(".app") { found.append(prefix) }
            }
            for bundle in found.reversed() where !result.contains(bundle) { result.append(bundle) }
        }
        return result
    }

    /// アプリとして起動されたか（親が launchd で、実行ファイルが `.app` の中）。そうなら、自分自身。
    static func ownApp() -> HostApp? {
        guard getppid() == 1, Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? ((Bundle.main.bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return HostApp(name: name, bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// このプロセスの親をたどって、`.app` の候補（内側が先）を返す。見つからなければ空（`ssh`・常駐の `tmux` の中など）。
    public static func candidates() -> [HostApp] {
        // vc.app として（Finder・ログイン項目から）起動されたなら、許可の持ち主は、vc.app 自身
        if let own = ownApp() { return [own] }
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
        return bundlePaths(in: paths).map { path in
            HostApp(name: String(((path as NSString).lastPathComponent).dropLast(".app".count)), bundleIdentifier: Bundle(path: path)?.bundleIdentifier)
        }
    }
}

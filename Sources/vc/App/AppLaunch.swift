import AppKit
import Foundation

/// 起動の入口の判断（**純粋**：テストできる）。実行ファイルが、**アプリ（`….app/Contents/MacOS/vc`）の中**で、引数がなければ、メニューバーのアプリ。引数があれば、CLI（スキルが使うコマンド）。
/// 端末から、引数なしで動かされたときは、端末の子として動かさず、アプリとして（LaunchServices で）起動する：端末の子だと、端末を閉じると終わり、マイクなどの許可も、このアプリでなく、端末のものになる。
enum LaunchMode: Equatable {
    case gui
    /// 端末から、引数なし：アプリを `open` で起動して、すぐ戻る（`bundle` は、`….app` のパス）。
    case openApp(bundle: String)
    case cli([String])
}

enum AppLaunch {
    /// `arguments`：実行ファイル名を除いた引数。`-psn_…`（古い起動の印）は、読み捨てる。
    static func mode(arguments: [String], executablePath: String?, isTerminal: Bool) -> LaunchMode {
        let real = arguments.filter { !$0.hasPrefix("-psn") }
        guard real.isEmpty, let executablePath, let bundle = bundlePath(forExecutable: executablePath) else { return .cli(real) }
        return isTerminal ? .openApp(bundle: bundle) : .gui
    }

    /// `…/X.app/Contents/MacOS/Y` の形の実行ファイルから、`X.app` のパス。その形でなければ `nil`（`swift run`・ビルドしたままの `vc`）。
    static func bundlePath(forExecutable path: String) -> String? {
        let marker = ".app/Contents/MacOS/"
        guard let range = path.range(of: marker, options: .backwards) else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// 実行ファイルの、実際の場所（`/usr/local/bin/vc` のリンクを辿る）。
    static var executablePath: String? {
        Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    /// アプリを起動する（LaunchServices）。起動できたら true。
    static func open(bundle: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [bundle]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

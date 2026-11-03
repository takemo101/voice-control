import AppKit
import Foundation
import VCCore

/// `agent-desktop` CLI を子プロセスで呼ぶ。画面の内容は、この Mac の中だけで扱い、ログに残さない。
public struct AgentDesktop: Desktop {
    public enum Failure: Error, Equatable { case launch(String), noOutput(Int32), failed(code: String, message: String), noFocusedField(app: String) }

    private let executable: String
    /// `nil` なら、前面のアプリ。
    private let app: String?
    public init(app: String? = nil, executable: String = "agent-desktop") { self.app = app; self.executable = executable }

    func run(_ arguments: [String]) throws -> Data {
        // 標準エラーは捨て、時間の上限は設けず、標準入力は引き継ぐ：これまでの呼び方のまま（上限を足すかは、別の判断）
        let result = ProcessRunner.run(executable: executable, arguments: arguments, mergeStderr: false, timeout: nil, inheritStandardInput: true)
        if let error = result.launchError { throw Failure.launch("\(error)") }
        // agent-desktop は、失敗も JSON（ok:false）で標準出力に返す。
        if result.output.isEmpty { throw Failure.noOutput(result.exitCode) }
        return result.output
    }

    func checked(_ arguments: [String]) throws {
        let root = try JSONSerialization.jsonObject(with: run(arguments)) as? [String: Any]
        guard root?["ok"] as? Bool == true else {
            let error = root?["error"] as? [String: Any]
            throw Failure.failed(code: (error?["code"] as? String) ?? "UNKNOWN", message: (error?["message"] as? String) ?? "")
        }
    }

    public func snapshot() throws -> Snapshot {
        try SnapshotParser.parse(run(["snapshot", "-i", "--include-bounds"] + (app.map { ["--app", $0] } ?? [])))
    }

    public func apps() throws -> [String] {
        let root = try JSONSerialization.jsonObject(with: run(["list-apps"])) as? [String: Any]
        let running = ((root?["data"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String ?? $0["app_name"] as? String }
        var seen = Set<String>(), out: [String] = []
        for name in running + Self.installedApps() where seen.insert(name).inserted { out.append(name) }
        return out
    }

    /// /Applications・/System/Applications・~/Applications の、アプリの名前（`.app` を除く）。
    static func installedApps() -> [String] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        // try?: 存在しないディレクトリは、アプリ 0 件（アプリ名の候補が減るだけ）
        return dirs.flatMap { (try? fm.contentsOfDirectory(atPath: $0)) ?? [] }.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }.sorted()
    }

    public func perform(_ step: Step) throws {
        switch step {
        case .openApp(let name): try openApp(name)
        case .click(let e): try checked(["click", e.ref])
        case .type(let text, let e): try checked(["type", e.ref, text])
        case .press(let s):
            for (i, combo) in s.combos.enumerated() {
                if i > 0 { Thread.sleep(forTimeInterval: 0.15) }
                try checked(["press", combo] + (app.map { ["--app", $0] } ?? []))
            }
        case .scroll(let d, let e): try checked(["scroll", e.ref, "--direction", d.rawValue])
        case .window(let a, let app): try windowAction(a, app: app)
        case .search(let query, let app): try search(query, app: app)
        case .element(let v, let e): try checked([v.rawValue, e.ref])
        case .closeApp(let name): try checked(["close-app", name])
        }
    }
}

extension AgentDesktop {
    static let browsers: Set<String> = ["Google Chrome", "Safari", "Arc", "Firefox", "Microsoft Edge", "Brave Browser", "Chromium", "Opera", "Vivaldi"]

    /// 検索：ブラウザはアドレスバー（cmd+L）、それ以外は検索（cmd+F）を、キーで選び、**フォーカスされた入力欄**に文字を入れて、リターンを押す。
    /// フォーカスされた入力欄が見つからなければ、何も入れずに失敗する（違う欄へ入れない）。
    func search(_ query: String, app: String) throws {
        try checked(["press", Self.browsers.contains(app) ? "cmd+l" : "cmd+f", "--app", app])
        Thread.sleep(forTimeInterval: 0.6)   // 欄が、フォーカスされるのを待つ
        let fields = try SnapshotParser.parse(run(["snapshot", "-i", "--app", app])).elements.filter(\.isTextInput)
        guard let field = fields.first(where: \.isFocused) else { throw Failure.noFocusedField(app: app) }
        try checked(["type", field.ref, query])
        try checked(["press", "return", "--app", app])
    }
}

extension AgentDesktop {
    private func windowBounds(app: String) -> [Double]? {
        // try?: 位置が読めなければ nil。呼び出し側が、元のエラー（TIMEOUT）を、そのまま投げる
        guard let root = try? JSONSerialization.jsonObject(with: run(["list-windows", "--app", app])) as? [String: Any],
              let windows = root["data"] as? [[String: Any]], let b = windows.first?["bounds"] as? [String: Any] else { return nil }
        return ["x", "y", "width", "height"].compactMap { b[$0] as? Double }
    }

    /// ウィンドウの操作。agent-desktop は、直前に snapshot を取ったあとの最初の操作で、実際には効いているのに TIMEOUT を返すことがある（実測：`retry: unsafe`、`delivered_unverified`）。
    /// 再実行は危険なので、TIMEOUT のときは、ウィンドウの位置・大きさが変わったかで、成功を判断する（変わっていなければ、失敗）。
    func windowAction(_ action: WindowAction, app: String) throws {
        let before = windowBounds(app: app)
        do { try checked([action.rawValue, "--app", app]) } catch let Failure.failed(code, message) where code == "TIMEOUT" {
            Thread.sleep(forTimeInterval: 0.5)
            guard let before, let after = windowBounds(app: app), before != after else { throw Failure.failed(code: code, message: message) }
        }
    }
}

extension AgentDesktop {
    public enum LaunchFailure: Error, Equatable { case open(status: Int32, name: String) }

    /// アプリを開いて前面に出す。macOS の `open -a`（LaunchServices）を使う。
    /// `agent-desktop launch` は、アプリ一覧に壊れた記録（pid -1）が 1 つあるだけで、`TIMEOUT`（application_inventory_unstable）になり、何も開かなかった（実測）。
    /// 開いたあと、そのアプリが前面になるまで（最大 10 秒）待つ：次の手が、そのアプリの画面で計画されるように。
    /// `ProcessRunner` には載せない：`/usr/bin/open` を絶対パスで直接起動し、起動の失敗は `Process` の元のエラーのまま投げる（`ProcessRunner` は env 経由で、失敗を終了コード 127 にする）。出力は読まず、標準出力・標準入力は引き継ぐ（`ProcessRunner` は、パイプで出力の終わりまで読む）。
    func openApp(_ name: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw LaunchFailure.open(status: p.terminationStatus, name: name) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.localizedName == name { showWindowIfNone(name); return }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}

extension AgentDesktop {
    public func frontAppName() -> String? { app ?? NSWorkspace.shared.frontmostApplication?.localizedName }

    /// ウィンドウが 1 つもないか（`list-windows`）。読めなければ `false`（分からないので、何もしない）。
    func hasNoWindows(of name: String) -> Bool {
        // try?: 読めなければ『分からない』（false）として、何もしない（ウィンドウを、勝手に出さない）
        guard let root = try? JSONSerialization.jsonObject(with: run(["list-windows", "--app", name])) as? [String: Any],
              root["ok"] as? Bool == true, let windows = root["data"] as? [Any] else { return false }
        return windows.isEmpty
    }

    /// `open -a` では、ウィンドウを出さないアプリがある（Spotify を、ウィンドウなしで起動した場合：実測）。ウィンドウがなければ、AppleScript の `activate` で、出す。
    /// 初回は、macOS が「このアプリがアプリ（名前）を制御しようとしています」の確認（オートメーションの許可）を出すことがある。
    /// `ProcessRunner` には載せない：`/usr/bin/osascript` を絶対パスで直接起動し、標準出力・標準エラーは /dev/null へ捨て、標準入力は引き継ぐ。パイプで出力の終わりまで読む `ProcessRunner` に載せると、終了待ちの条件が変わる。
    func showWindowIfNone(_ name: String) {
        guard hasNoWindows(of: name) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        p.arguments = ["-e", "tell application \"\(escaped)\" to activate"]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        // try?: ウィンドウを出すための AppleScript は、最善の努力。失敗しても、ここでは知らせない（開く操作そのものは、すでに成功している）
        try? p.run()
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 1)
    }
}

import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool
}

public enum CommandRunner {
    /// コマンドを、シェルなしで実行する（`/usr/bin/env` で PATH を探す）。標準出力と標準エラーを、まとめて返す。
    /// `cancel` が取りやめられたら、実行中のコマンドを止める（終了コード 130）。
    public static func run(argv: [String], timeout: TimeInterval = 30, cancel: CancelToken? = nil) -> CommandResult {
        if cancel?.isCancelled == true { return CommandResult(exitCode: 130, output: "取りやめ", timedOut: false) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return CommandResult(exitCode: 127, output: "起動できない: \(error.localizedDescription)", timedOut: false) }
        cancel?.onCancel { if p.isRunning { p.terminate() } }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = group.wait(timeout: .now() + 2)
        }
        p.waitUntilExit()
        let wasCancelled = cancel?.isCancelled == true
        return CommandResult(exitCode: wasCancelled ? 130 : p.terminationStatus, output: wasCancelled ? "取りやめ" : String(decoding: data, as: UTF8.self), timedOut: timedOut)
    }
}

/// 言語モデルに返す出力の、整形。モデルの入力には上限（約 4000 トークン）があるので、短くする。
public enum OutputCompactor {
    public static let maxChars = 1800

    /// - agent-desktop の `snapshot`：JSON を、「@参照 [役割] 名前」の行にする（操作できる要素だけ。続く `click @参照` に、そのまま使える）。
    /// - agent-desktop のその他：結果（ok / エラーの種類と文）だけ。
    /// - それ以外：そのまま（長ければ切る）。
    public static func compact(argv: [String], output: String, aliases: RefAliases = RefAliases()) -> String {
        let text: String
        if argv.first == "agent-desktop", let compacted = compactAgentDesktop(argv: argv, output: output, aliases: aliases) { text = compacted } else { text = output }
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars)) + "\n…（\(text.count - maxChars) 文字を省略）"
    }

    static func compactAgentDesktop(argv: [String], output: String, aliases: RefAliases) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
        guard root["ok"] as? Bool == true else {
            let e = root["error"] as? [String: Any]
            return "error \((e?["code"] as? String) ?? "UNKNOWN"): \((e?["message"] as? String) ?? "")"
        }
        guard argv.contains("snapshot"), let data = root["data"] as? [String: Any], let tree = data["tree"] as? [String: Any] else { return "ok" }
        var lines = ["app: \((data["app"] as? String) ?? "?")"]
        func walk(_ node: [String: Any]) {
            if let ref = node["ref_id"] as? String, let role = node["role"] as? String,
               let actions = node["available_actions"] as? [String], !actions.isEmpty {
                let states = (node["states"] as? [String]) ?? []
                if !states.contains("hidden") && !states.contains("disabled") {
                    let name = (node["name"] as? String) ?? ""
                    lines.append("\(aliases.shorten(ref)) [\(role)] \(name.isEmpty ? "(no name)" : String(name.prefix(40)))\(states.contains("focused") ? " (focused)" : "")")
                }
            }
            for child in (node["children"] as? [[String: Any]]) ?? [] { walk(child) }
        }
        walk(tree)
        return lines.prefix(60).joined(separator: "\n")
    }
}

/// agent-desktop の参照（`@s17tb038elj2nz:e13`）は、長いランダムな文字列で、言語モデルが、写し間違える（`@s20:e18` に縮める：測定）。
/// 言語モデルには、短い別名（`@a1:e13`）を見せ、実行の直前に、元の参照に戻す。
public final class RefAliases: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: String] = [:]      // 元の snapshot id → 別名
    private var byAlias: [String: String] = [:]   // 別名 → 元の snapshot id

    public init() {}

    private static func split(_ ref: String) -> (id: String, rest: String)? {
        guard ref.hasPrefix("@"), let colon = ref.firstIndex(of: ":") else { return nil }
        return (String(ref[ref.index(after: ref.startIndex)..<colon]), String(ref[colon...]))
    }

    /// `@元の id:e13` → `@a1:e13`。
    public func shorten(_ ref: String) -> String {
        guard let (id, rest) = Self.split(ref) else { return ref }
        lock.lock(); defer { lock.unlock() }
        if byID[id] == nil {
            let alias = "a\(byID.count + 1)"
            byID[id] = alias
            byAlias[alias] = id
        }
        return "@\(byID[id]!)\(rest)"
    }

    /// `@a1:e13` → `@元の id:e13`。別名でなければ、そのまま。
    public func expand(_ token: String) -> String {
        guard let (alias, rest) = Self.split(token) else { return token }
        lock.lock(); defer { lock.unlock() }
        return byAlias[alias].map { "@\($0)\(rest)" } ?? token
    }
}

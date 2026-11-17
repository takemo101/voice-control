import Foundation
import VCCore

/// ACP アダプター 1 つ（`claude`・`codex`：CLI 本体は、ACP を話さないので、**CLI を ACP に変える、別のプログラム**〔npm のパッケージ〕）。**版を固定**して、利用者が選んだときだけ、`~/.voice-control/adapters/<名前>/` に入れる（`ACPAdapterInstaller`）。
/// 固定した版と、`adapters/<名前>/package.json`・`package-lock.json`（同梱）は、一致させる（テストが照らす）。更新は、`scripts/update-adapters.sh`。
public struct ACPAdapter: Equatable, Sendable {
    public let agent: ChatAgent
    /// npm のパッケージ名。
    public let package: String
    /// 固定した版（lock と同じ）。
    public let version: String
    /// アダプターの実行ファイルの名前（`node_modules/.bin/` の中）。
    public let executable: String
    public let license: String
    /// 入れたときの、おおよその大きさ（MB。CLI 本体を、二重に取り込まない：利用者が入れた CLI を使う）。
    public let approximateSizeMB: Int
    /// アダプターが、**利用者の CLI 本体**の場所を受け取る、環境変数（本体を、二重に取り込まないため）。
    public let cliEnvironmentKey: String

    public var directoryName: String { agent.rawValue }

    public static func of(_ agent: ChatAgent) -> ACPAdapter? {
        switch agent {
        case .claude: return ACPAdapter(agent: .claude, package: "@agentclientprotocol/claude-agent-acp", version: "0.108.0", executable: "claude-agent-acp", license: "Apache-2.0", approximateSizeMB: 80, cliEnvironmentKey: "CLAUDE_CODE_EXECUTABLE")
        case .codex: return ACPAdapter(agent: .codex, package: "@agentclientprotocol/codex-acp", version: "2.7.0", executable: "codex-acp", license: "Apache-2.0", approximateSizeMB: 25, cliEnvironmentKey: "CODEX_PATH")
        default: return nil
        }
    }
}

/// 入れた場所と、入っている版（**ファイルを読むだけ**）。
public enum ACPAdapterStore {
    public static var root: URL { VoiceControlHome.root.appendingPathComponent("adapters") }

    public static func directory(for adapter: ACPAdapter, root: URL = root) -> URL { root.appendingPathComponent(adapter.directoryName) }

    /// 実行ファイルのある所（`node_modules/.bin`）。
    public static func binDirectory(for adapter: ACPAdapter, root: URL = root) -> String {
        directory(for: adapter, root: root).appendingPathComponent("node_modules/.bin").path
    }

    /// 入れてある版（アダプターの `package.json` の `version`）。実行ファイルがなければ、入っていない（nil）。
    public static func installedVersion(of adapter: ACPAdapter, root: URL = root) -> String? {
        let directory = directory(for: adapter, root: root)
        guard FileManager.default.isExecutableFile(atPath: binDirectory(for: adapter, root: root) + "/" + adapter.executable),
              let data = try? Data(contentsOf: directory.appendingPathComponent("node_modules/\(adapter.package)/package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }
}

/// 同梱の固定ファイル（`package.json`・`package-lock.json`）の検査（**純粋**）：**取得先は、npm の公式のレジストリだけ・すべての部品に、SHA-512 の整合値がある・入れるのは、固定した版だけ**。違えば、入れない。
public enum ACPAdapterLock {
    public static func problems(packageJSON: Data, lock: Data, adapter: ACPAdapter) -> [String] {
        var found: [String] = []
        guard let manifest = try? JSONSerialization.jsonObject(with: packageJSON) as? [String: Any],
              let dependencies = manifest["dependencies"] as? [String: String] else { return ["package.json を読めません"] }
        if dependencies != [adapter.package: adapter.version] { found.append("package.json の依存が、固定した版（\(adapter.package)@\(adapter.version)）だけではありません") }
        guard let object = try? JSONSerialization.jsonObject(with: lock) as? [String: Any], let packages = object["packages"] as? [String: [String: Any]] else {
            return found + ["package-lock.json を読めません"]
        }
        if (object["lockfileVersion"] as? Int ?? 0) < 2 { found.append("package-lock.json の形式が古すぎます") }
        let root = packages[""]?["dependencies"] as? [String: String]
        if root != [adapter.package: adapter.version] { found.append("lock の根の依存が、固定した版と違います") }
        if packages["node_modules/\(adapter.package)"]?["version"] as? String != adapter.version { found.append("lock の中の \(adapter.package) の版が、固定した版（\(adapter.version)）と違います") }
        for (path, entry) in packages where !path.isEmpty {
            guard let integrity = entry["integrity"] as? String, integrity.hasPrefix("sha512-") else { found.append("\(path)：SHA-512 の整合値がありません"); continue }
            guard let resolved = entry["resolved"] as? String, resolved.hasPrefix("https://registry.npmjs.org/") else { found.append("\(path)：取得先が、npm の公式のレジストリではありません"); continue }
        }
        return found
    }
}

/// アダプターを入れる・消す。**利用者が選んだときだけ呼ぶ**（`vc adapter install`・設定ウィンドウ）。
/// 手順：同梱の固定ファイルを検査 → 作業の場所へ写す → `npm ci --ignore-scripts --omit=optional`（lock どおり・インストール時のスクリプトは動かさない・CLI 本体は取り込まない）→ 入った版・実行ファイルを確かめる → **入れ替え**（失敗したら、前のものが残る）。
public enum ACPAdapterInstaller {
    public enum Failure: Error, CustomStringConvertible {
        case nodeMissing
        case sourceMissing(String)
        case rejected([String])
        case npmFailed(String)
        case verifyFailed(String)
        case cancelled
        case filesystem(String)

        public var description: String {
            switch self {
            case .nodeMissing: return "Node.js（npm）が、見つかりません。先に Node.js を入れてください（https://nodejs.org ・ nvm など）"
            case let .sourceMissing(path): return "同梱の固定ファイルが、見つかりません（\(path)）"
            case let .rejected(problems): return "固定ファイルの検査に通りませんでした：" + problems.prefix(3).joined(separator: "／")
            case let .npmFailed(why): return "npm が失敗しました：\(why)"
            case let .verifyFailed(why): return "入れたものが、想定と違います：\(why)"
            case .cancelled: return "取りやめました"
            case let .filesystem(why): return "ファイルを書けませんでした：\(why)"
            }
        }
    }

    /// `npm` を動かす（テストで、差し替える）。引数・作業の場所・環境を渡して、結果を得る。
    public typealias NPMRunner = @Sendable (_ arguments: [String], _ directory: URL, _ environment: [String: String]) -> ProcessResult

    /// 実際の `npm`（探す場所は、`AgentLocator`：`PATH`・よくある置き場所・`nvm`）。見つからなければ nil。
    public static func npmPath(directories: [String] = AgentLocator.searchDirectories()) -> String? {
        directories.map { "\($0)/npm" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static let liveRunner: NPMRunner = { arguments, directory, environment in
        guard let npm = npmPath() else { return ProcessResult(exitCode: 127, output: Data("npm が見つかりません".utf8), timedOut: false, cancelled: false, launchError: nil) }
        return ProcessRunner.run(executable: npm, arguments: arguments, mergeStderr: true, timeout: 600, workingDirectory: directory, environment: environment)
    }

    /// 入れる。`source`：同梱の固定ファイルのある場所（`<source>/package.json`・`package-lock.json`）。`root`：入れ先（`~/.voice-control/adapters`）。
    public static func install(_ adapter: ACPAdapter, source: URL, root: URL = ACPAdapterStore.root, run: @escaping NPMRunner = liveRunner, hasNode: () -> Bool = { npmPath() != nil }) async throws {
        guard hasNode() else { throw Failure.nodeMissing }
        let packageFile = source.appendingPathComponent("package.json"), lockFile = source.appendingPathComponent("package-lock.json")
        guard let packageJSON = try? Data(contentsOf: packageFile) else { throw Failure.sourceMissing(packageFile.path) }
        guard let lock = try? Data(contentsOf: lockFile) else { throw Failure.sourceMissing(lockFile.path) }
        let problems = ACPAdapterLock.problems(packageJSON: packageJSON, lock: lock, adapter: adapter)
        guard problems.isEmpty else { throw Failure.rejected(problems) }

        let fileManager = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try packageJSON.write(to: staging.appendingPathComponent("package.json"))
            try lock.write(to: staging.appendingPathComponent("package-lock.json"))
        } catch { throw Failure.filesystem("\(error.localizedDescription)") }

        let environment = ["PATH": AgentLocator.childPATH(), "npm_config_update_notifier": "false", "npm_config_fund": "false", "npm_config_audit": "false"]
        let result = await Task.detached { run(["ci", "--ignore-scripts", "--omit=optional", "--no-audit", "--no-fund", "--no-progress"], staging, environment) }.value
        if Task.isCancelled || result.cancelled { throw Failure.cancelled }
        guard result.exitCode == 0 else {
            let tail = result.text.split(whereSeparator: \.isNewline).suffix(4).joined(separator: " ")
            throw Failure.npmFailed(result.timedOut ? "時間がかかりすぎました" : (tail.isEmpty ? "終了コード \(result.exitCode)" : String(tail.prefix(300))))
        }
        // 入ったものを確かめる（実行ファイル・版）
        let executable = staging.appendingPathComponent("node_modules/.bin/\(adapter.executable)").path
        guard fileManager.isExecutableFile(atPath: executable) else { throw Failure.verifyFailed("実行ファイル（\(adapter.executable)）が、ありません") }
        let installedPackage = staging.appendingPathComponent("node_modules/\(adapter.package)/package.json")
        guard let data = try? Data(contentsOf: installedPackage), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["version"] as? String == adapter.version else {
            throw Failure.verifyFailed("版が、固定した版（\(adapter.version)）と違います")
        }
        // 入れ替え：前のものは、いったん、脇へ。置けなければ、戻す
        let destination = ACPAdapterStore.directory(for: adapter, root: root)
        let backup = root.appendingPathComponent(".old-\(UUID().uuidString)")
        let hadOld = fileManager.fileExists(atPath: destination.path)
        do {
            if hadOld { try fileManager.moveItem(at: destination, to: backup) }
            do { try fileManager.moveItem(at: staging, to: destination) } catch {
                if hadOld { try? fileManager.moveItem(at: backup, to: destination) }
                throw error
            }
            if hadOld { try? fileManager.removeItem(at: backup) }
        } catch { throw Failure.filesystem("\(error.localizedDescription)") }
    }

    /// 消す（入れたフォルダだけ）。
    public static func remove(_ adapter: ACPAdapter, root: URL = ACPAdapterStore.root) throws {
        let directory = ACPAdapterStore.directory(for: adapter, root: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do { try FileManager.default.removeItem(at: directory) } catch { throw Failure.filesystem("\(error.localizedDescription)") }
    }
}

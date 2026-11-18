import Foundation
import Testing
import VCCore
@testable import VCSkill

/// ACP アダプター：同梱の固定ファイルの検査・入れる手順（偽の npm で）・入れた場所の見方・探す順。
@Suite struct ACPAdapterTests {
    private let claude = ACPAdapter.of(.claude)!, codex = ACPAdapter.of(.codex)!

    /// リポジトリの `adapters/<名前>`（テストの場所から、上へ）。
    private func bundled(_ adapter: ACPAdapter) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("adapters/\(adapter.directoryName)")
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: 同梱のファイル（実際のもの）

    @Test func theBundledPinnedFilesPassTheCheckAndMatchThePinnedVersions() throws {
        for adapter in [claude, codex] {
            let dir = bundled(adapter)
            let problems = ACPAdapterLock.problems(packageJSON: try Data(contentsOf: dir.appendingPathComponent("package.json")), lock: try Data(contentsOf: dir.appendingPathComponent("package-lock.json")), adapter: adapter)
            #expect(problems.isEmpty, "\(adapter.agent): \(problems)")
        }
    }

    // MARK: 検査

    private func lock(version: String = "0.108.0", dependency: String? = nil, extra: [String: [String: Any]] = [:], dropIntegrity: Bool = false) -> (package: Data, lock: Data) {
        var packages: [String: [String: Any]] = [
            "": ["dependencies": [claude.package: dependency ?? version]],
            "node_modules/\(claude.package)": ["version": version, "resolved": "https://registry.npmjs.org/x.tgz", "integrity": "sha512-AAAA"],
            "node_modules/dep": ["version": "1.0.0", "resolved": "https://registry.npmjs.org/dep.tgz", "integrity": dropIntegrity ? "sha1-AAAA" : "sha512-BBBB"],
        ]
        for (key, value) in extra { packages[key] = value }
        let lockData = try! JSONSerialization.data(withJSONObject: ["lockfileVersion": 3, "packages": packages])
        let manifest = try! JSONSerialization.data(withJSONObject: ["dependencies": [claude.package: version]])
        return (manifest, lockData)
    }

    @Test func aLockWithEveryPartHashedFromTheOfficialRegistryAtThePinnedVersionIsAccepted() {
        let files = lock()
        #expect(ACPAdapterLock.problems(packageJSON: files.package, lock: files.lock, adapter: claude).isEmpty)
    }

    @Test func aLockWithAnotherVersionAForeignSourceOrAMissingHashIsRejected() {
        var files = lock(version: "9.9.9")
        #expect(!ACPAdapterLock.problems(packageJSON: files.package, lock: files.lock, adapter: claude).isEmpty)                       // 固定した版と違う
        files = lock(extra: ["node_modules/evil": ["version": "1", "resolved": "https://evil.example/evil.tgz", "integrity": "sha512-CC"]])
        #expect(ACPAdapterLock.problems(packageJSON: files.package, lock: files.lock, adapter: claude).contains { $0.contains("公式のレジストリ") })   // 取得先
        files = lock(extra: ["node_modules/git": ["version": "1", "resolved": "git+ssh://git@github.com/x/y.git"]])
        #expect(!ACPAdapterLock.problems(packageJSON: files.package, lock: files.lock, adapter: claude).isEmpty)                       // git の取得
        files = lock(dropIntegrity: true)
        #expect(ACPAdapterLock.problems(packageJSON: files.package, lock: files.lock, adapter: claude).contains { $0.contains("SHA-512") })   // sha1 などは、不可
        files = lock(dependency: "^0.108.0")
        #expect(!ACPAdapterLock.problems(packageJSON: files.package, lock: files.lock, adapter: claude).isEmpty)                       // 範囲の指定は、不可（固定だけ）
        #expect(!ACPAdapterLock.problems(packageJSON: Data("{}".utf8), lock: files.lock, adapter: claude).isEmpty)
        #expect(!ACPAdapterLock.problems(packageJSON: files.package, lock: Data("x".utf8), adapter: claude).isEmpty)
    }

    // MARK: 入れる（偽の npm）

    /// 偽の npm：`ci` で、`node_modules` に、実行ファイルとパッケージを作る（`version` を、変えられる）。
    private func fakeNPM(version: String? = nil, exitCode: Int32 = 0, createBinary: Bool = true, record: ACPCollected<[String]>? = nil) -> ACPAdapterInstaller.NPMRunner {
        let wantedVersion = version ?? claude.version
        return { arguments, directory, environment in
            record?.add(arguments + ["PATH=" + (environment["PATH"] ?? "")])
            guard exitCode == 0 else { return ProcessResult(exitCode: exitCode, output: Data("npm ERR! boom\nnpm ERR! last line".utf8), timedOut: false, cancelled: false, launchError: nil) }
            let fm = FileManager.default
            let bin = directory.appendingPathComponent("node_modules/.bin"), pkg = directory.appendingPathComponent("node_modules/\(claude.package)")
            try? fm.createDirectory(at: bin, withIntermediateDirectories: true); try? fm.createDirectory(at: pkg, withIntermediateDirectories: true)
            try? Data("{\"version\":\"\(wantedVersion)\"}".utf8).write(to: pkg.appendingPathComponent("package.json"))
            if createBinary {
                let file = bin.appendingPathComponent(claude.executable)
                try? Data("#!/bin/sh\n".utf8).write(to: file)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            return ProcessResult(exitCode: 0, output: Data(), timedOut: false, cancelled: false, launchError: nil)
        }
    }

    private func sourceFor(_ adapter: ACPAdapter) -> URL { bundled(adapter) }

    @Test func installingRunsALockedNpmCiWithoutScriptsOrOptionalPartsAndLeavesNoStagingBehind() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let record = ACPCollected<[String]>()
        try await ACPAdapterInstaller.install(claude, source: sourceFor(claude), root: root, run: fakeNPM(record: record), hasNode: { true })
        let call = try #require(record.all.first)
        #expect(call.starts(with: ["ci", "--ignore-scripts", "--omit=optional"]))                       // lock どおり・スクリプトなし・CLI 本体を取り込まない
        #expect(ACPAdapterStore.installedVersion(of: claude, root: root) == claude.version)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["claude"])   // 作業の場所・退避が、残らない
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("claude/package-lock.json").path))
    }

    @Test func aFailedOrMismatchedInstallKeepsThePreviousInstallAndReportsWhy() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try await ACPAdapterInstaller.install(claude, source: sourceFor(claude), root: root, run: fakeNPM(), hasNode: { true })
        // npm の失敗
        await #expect(throws: ACPAdapterInstaller.Failure.self) { try await ACPAdapterInstaller.install(claude, source: sourceFor(claude), root: root, run: fakeNPM(exitCode: 1), hasNode: { true }) }
        // 入った版が、固定した版と違う
        await #expect(throws: ACPAdapterInstaller.Failure.self) { try await ACPAdapterInstaller.install(claude, source: sourceFor(claude), root: root, run: fakeNPM(version: "0.0.1"), hasNode: { true }) }
        // 実行ファイルがない
        await #expect(throws: ACPAdapterInstaller.Failure.self) { try await ACPAdapterInstaller.install(claude, source: sourceFor(claude), root: root, run: fakeNPM(createBinary: false), hasNode: { true }) }
        #expect(ACPAdapterStore.installedVersion(of: claude, root: root) == claude.version)             // 前のものが、残っている
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["claude"])
        do { try await ACPAdapterInstaller.install(claude, source: sourceFor(claude), root: root, run: fakeNPM(exitCode: 1), hasNode: { true }) }
        catch { #expect("\(error)".contains("last line")) }                                             // npm の最後の行を、理由に出す
    }

    @Test func withoutNodeNothingIsAttemptedAndABrokenSourceIsRefusedBeforeNpmRuns() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let ran = ACPCollected<[String]>()
        await #expect(throws: ACPAdapterInstaller.Failure.self) { try await ACPAdapterInstaller.install(claude, source: sourceFor(claude), root: root, run: fakeNPM(record: ran), hasNode: { false }) }
        let bad = try tempRoot(); defer { try? FileManager.default.removeItem(at: bad) }
        await #expect(throws: ACPAdapterInstaller.Failure.self) { try await ACPAdapterInstaller.install(claude, source: bad, root: root, run: fakeNPM(record: ran), hasNode: { true }) }   // 固定ファイルがない
        #expect(ran.all.isEmpty)                                                                        // npm は、動かしていない
    }

    @Test func removingDeletesOnlyThatAdaptersFolder() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try await ACPAdapterInstaller.install(claude, source: sourceFor(claude), root: root, run: fakeNPM(), hasNode: { true })
        let other = root.appendingPathComponent("codex"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try ACPAdapterInstaller.remove(claude, root: root)
        #expect(ACPAdapterStore.installedVersion(of: claude, root: root) == nil && FileManager.default.fileExists(atPath: other.path))
        try ACPAdapterInstaller.remove(claude, root: root)                                              // もう、ない：何も起きない
    }

    // MARK: 探す順

    @Test func theUsersOwnAdapterIsPreferredThenTheOneTheAppInstalledAndTheCliIsPassedByEnvironment() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try await ACPAdapterInstaller.install(claude, source: sourceFor(claude), root: root, run: fakeNPM(), hasNode: { true })
        let managed = ACPAdapterStore.binDirectory(for: claude, root: root) + "/claude-agent-acp"
        func exec(_ allowed: Set<String>) -> (String) -> Bool { { allowed.contains($0) } }
        #expect(AgentLocator.acpExecutablePath(for: .claude, directories: ["/own"], managedRoot: root, isExecutable: exec(["/own/claude-agent-acp", managed])) == "/own/claude-agent-acp")
        #expect(AgentLocator.acpExecutablePath(for: .claude, directories: ["/own"], managedRoot: root, isExecutable: exec([managed])) == managed)
        #expect(AgentLocator.acpExecutablePath(for: .claude, directories: ["/own"], managedRoot: root, isExecutable: exec([])) == nil)
        #expect(AgentLocator.acpExecutablePath(for: .agy, directories: ["/own"], managedRoot: root, isExecutable: exec(["/own/agy"])) == "/own/agy")   // agy・opencode は、本体
        // アダプターは、利用者の CLI 本体を使う（二重に取り込まない）
        #expect(AgentLocator.cliEnvironment(for: .claude, directories: ["/bin1"], isExecutable: exec(["/bin1/claude"])) == ["CLAUDE_CODE_EXECUTABLE": "/bin1/claude"])
        #expect(AgentLocator.cliEnvironment(for: .codex, directories: ["/bin1"], isExecutable: exec(["/bin1/codex"])) == ["CODEX_PATH": "/bin1/codex"])
        #expect(AgentLocator.cliEnvironment(for: .claude, directories: ["/bin1"], isExecutable: exec([])).isEmpty && AgentLocator.cliEnvironment(for: .agy).isEmpty)
    }
}

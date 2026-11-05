import Foundation
import Testing
@testable import VCSkill

/// GitHub からのスキルの取得（`vc skills install`）。通信は、偽の `Fetch` に差し替える。
@Suite struct RemoteSkillsTests {
    private let skillMd = "---\nname: demo\ndescription: x\nallowed-commands:\n  - osascript ${SKILL_DIR}/run.applescript\n---\nbody"

    private func tree(_ extra: [[String: Any]] = [], truncated: Bool = false) -> Data {
        func item(_ path: String, mode: String = "100644", type: String = "blob", size: Int = 10) -> [String: Any] { ["path": path, "mode": mode, "type": type, "size": size] }
        let items: [[String: Any]] = [
            item("README.md"),
            item(".voice-control", mode: "040000", type: "tree"),
            item(".voice-control/skills/demo", mode: "040000", type: "tree"),
            item(".voice-control/skills/demo/SKILL.md"),
            item(".voice-control/skills/demo/run.applescript", mode: "100755"),
            item(".voice-control/skills/demo/sub/helper.txt"),
            item(".voice-control/skills/other/SKILL.md"),
            item(".voice-control/skills/other/data.txt"),
            item(".voice-control/skills/Bad_Name/SKILL.md"),
            item(".voice-control/skills/stray.txt"),
        ] + extra
        return try! JSONSerialization.data(withJSONObject: ["tree": items, "truncated": truncated])
    }

    /// 取得した URL を記録し、ツリー・ファイルを返す偽物。
    private final class Server: @unchecked Sendable {
        let lock = NSLock(); private(set) var urls: [String] = []
        let treeData: Data; let treeStatus: Int; let skillMd: String
        init(tree: Data, treeStatus: Int = 200, skillMd: String) { treeData = tree; self.treeStatus = treeStatus; self.skillMd = skillMd }
        var fetch: RemoteSkills.Fetch {
            { [self] url in
                lock.lock(); urls.append(url.absoluteString); lock.unlock()
                if url.host == "api.github.com" { return (treeData, treeStatus) }
                let name = url.lastPathComponent
                return (Data((name == "SKILL.md" ? skillMd : "content of \(name)").utf8), 200)
            }
        }
    }

    private func staging() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID().uuidString)") }

    @Test func aNamedSkillIsDownloadedWithItsWholeDirectoryAndTheOthersAreNot() async throws {
        let server = Server(tree: tree(), skillMd: skillMd), dir = staging()
        try await RemoteSkills.download(names: ["demo"], ref: "v0.1.3", into: dir, fetch: server.fetch)
        #expect(try String(contentsOf: dir.appendingPathComponent("demo/SKILL.md"), encoding: .utf8) == skillMd)
        #expect(try String(contentsOf: dir.appendingPathComponent("demo/sub/helper.txt"), encoding: .utf8) == "content of helper.txt")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("other").path))
        #expect((try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("demo/run.applescript").path)[.posixPermissions] as? Int) == 0o755)
        // 固定のリポジトリ・版（タグ）から取る
        #expect(server.urls.contains("https://raw.githubusercontent.com/takemo101/voice-control/v0.1.3/.voice-control/skills/demo/SKILL.md"))
        #expect(server.urls.first == "https://api.github.com/repos/takemo101/voice-control/git/trees/v0.1.3?recursive=1")
    }

    @Test func withoutNamesOnlyTheSkillFilesOfEverySkillAreFetchedForTheListing() async throws {
        let server = Server(tree: tree(), skillMd: skillMd), dir = staging()
        try await RemoteSkills.download(names: nil, ref: "main", into: dir, fetch: server.fetch)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["demo", "other"])   // 使えない名前（Bad_Name）・SKILL.md のない場所は、取らない
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("demo/run.applescript").path))
    }

    @Test func aSkillWithASymbolicLinkIsRefusedBeforeAnythingIsDownloaded() async {
        let server = Server(tree: tree([["path": ".voice-control/skills/demo/link", "mode": "120000", "type": "blob", "size": 5]]), skillMd: skillMd), dir = staging()
        await #expect(throws: RemoteSkills.Failure.containsSymlink(name: "demo", path: "link")) { try await RemoteSkills.download(names: ["demo"], ref: "main", into: dir, fetch: server.fetch) }
        #expect(!server.urls.contains { $0.hasPrefix("https://raw.") })
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func anUnknownVersionATruncatedListAndAnOversizedSkillAreFailuresNotPartialResults() async {
        let dir = staging()
        await #expect(throws: RemoteSkills.Failure.refNotFound("v9.9.9")) { try await RemoteSkills.download(names: nil, ref: "v9.9.9", into: dir, fetch: Server(tree: Data(), treeStatus: 404, skillMd: "").fetch) }
        await #expect(throws: RemoteSkills.Failure.self) { try await RemoteSkills.download(names: nil, ref: "main", into: dir, fetch: Server(tree: tree(truncated: true), skillMd: "").fetch) }
        let big = Server(tree: tree([["path": ".voice-control/skills/demo/huge.bin", "mode": "100644", "type": "blob", "size": RemoteSkills.maxFileBytes + 1]]), skillMd: skillMd)
        await #expect(throws: RemoteSkills.Failure.self) { try await RemoteSkills.download(names: ["demo"], ref: "main", into: dir, fetch: big.fetch) }
    }

    @Test func aServerErrorOnAFileIsReportedAndNetworkErrorsAreWrapped() async {
        let dir = staging()
        let failing: RemoteSkills.Fetch = { url in
            if url.host == "api.github.com" { return (try JSONSerialization.data(withJSONObject: ["tree": [["path": ".voice-control/skills/demo/SKILL.md", "mode": "100644", "type": "blob", "size": 5]]]), 200) }
            return (Data(), 503)
        }
        await #expect(throws: RemoteSkills.Failure.network(".voice-control/skills/demo/SKILL.md：HTTP 503")) { try await RemoteSkills.download(names: ["demo"], ref: "main", into: dir, fetch: failing) }
        struct Offline: Error {}
        await #expect(throws: RemoteSkills.Failure.self) { try await RemoteSkills.download(names: nil, ref: "main", into: dir, fetch: { _ in throw Offline() }) }
    }

    /// 取得 → グローバルへ置く（`SkillInstaller`）までの流れ。置いたスキルは、グローバルの場所を指す。
    @Test func aDownloadedSkillCanBeInstalledGlobally() async throws {
        let server = Server(tree: tree(), skillMd: skillMd), dir = staging()
        let global = FileManager.default.temporaryDirectory.appendingPathComponent("global-\(UUID().uuidString)")
        try await RemoteSkills.download(names: ["demo"], ref: "main", into: dir, fetch: server.fetch)
        let result = try SkillInstaller.install(name: "demo", from: dir, to: global, overwrite: false)
        #expect(result.allowedCommands == ["osascript \(global.appendingPathComponent("demo").path)/run.applescript"])
        #expect(SkillStore.load(directory: global).skills.map(\.name) == ["demo"])
    }
}

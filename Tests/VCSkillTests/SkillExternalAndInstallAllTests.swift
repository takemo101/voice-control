import Foundation
import Testing
@testable import VCSkill

/// スキルの `external`（発話を、この Mac の外へ送る先）と、`vc skills install --all`（リポジトリの、すべてのスキルを置く）。
@Suite struct SkillExternalAndInstallAllTests {
    private func parse(_ front: String) -> Skill? {
        try? SkillStore.parse("---\nname: demo\ndescription: x\nallowed-commands: echo\n\(front)---\nbody", directoryName: "demo", file: URL(fileURLWithPath: "/tmp/demo/SKILL.md")).get()
    }

    /// 書かなければ、送らない（nil）。書けば、その文字。空は、書かないのと同じ。
    @Test func externalIsNilUnlessWritten() {
        #expect(parse("")?.external == nil)
        #expect(parse("external: Google（agy）\n")?.external == "Google（agy）")
        #expect(parse("external:\n")?.external == nil)
    }

    /// 偽のリポジトリ：スキル 2 つ（`alpha`・`beta`〔external つき〕）と、読めないもの（`broken`）。
    private final class Repo: @unchecked Sendable {
        private let lock = NSLock(); private(set) var refs: [String] = []
        let files: [String: String] = [
            ".voice-control/skills/alpha/SKILL.md": "---\nname: alpha\ndescription: a\nallowed-commands: echo\n---\nRun.",
            ".voice-control/skills/beta/SKILL.md": "---\nname: beta\ndescription: b\nallowed-commands: echo\nexternal: どこか\n---\nRun.",
            ".voice-control/skills/broken/SKILL.md": "フロントマターがない",
        ]
        var fetch: RemoteSkills.Fetch {
            { [self] url in
                if url.host == "api.github.com" {
                    let ref = url.pathComponents.last ?? ""
                    lock.lock(); refs.append(ref); lock.unlock()
                    guard ref == "main" else { return (Data(), 404) }   // タグは、ない：main に切り替わる
                    let tree = files.keys.sorted().map { ["path": $0, "mode": "100644", "type": "blob", "size": 10] as [String: Any] }
                    return (try JSONSerialization.data(withJSONObject: ["tree": tree]), 200)
                }
                let path = files.keys.first { url.absoluteString.hasSuffix($0) } ?? ""
                return (Data((files[path] ?? "").utf8), 200)
            }
        }
    }

    /// すべてのスキルを置く：読めないものは、置かず、`problems` に出す。タグがなく、main に切り替えても、一覧と置くものは、同じ版（main）。
    @Test func installAllPlacesEveryReadableSkillFromTheSameRef() async throws {
        let repo = Repo()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ia-\(UUID().uuidString)")
        let (report, problems) = try await RemoteInstall.installAll(explicitRef: nil, defaultRef: "v9.9.9", overwrite: false, to: dir, fetch: repo.fetch)
        #expect(report.source == .init(ref: "main", fellBackToMain: true))
        #expect(report.outcomes.map(\.name) == ["alpha", "beta"])
        let installed = report.outcomes.compactMap { try? $0.result.get() }
        #expect(installed.count == 2 && installed.first { $0.name == "beta" }?.external == "どこか" && installed.first { $0.name == "alpha" }?.external == nil)
        #expect(problems.count == 1 && FileManager.default.fileExists(atPath: dir.appendingPathComponent("alpha/SKILL.md").path) && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("broken").path))
        // 1 回目の一覧で、v9.9.9 → main。置くときは、main を指定する（もう一度、v9.9.9 を試さない）
        #expect(repo.refs.filter { $0 == "v9.9.9" }.count == 1)
    }

    /// すでにあるものは、`--force` なしでは、置き換えず、結果に出る（ほかは、置く）。
    @Test func installAllReportsExistingSkillsAndStillPlacesTheRest() async throws {
        let repo = Repo()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ia-\(UUID().uuidString)")
        _ = try await RemoteInstall.install(names: ["alpha"], explicitRef: "main", defaultRef: "main", overwrite: false, to: dir, fetch: repo.fetch)
        let (report, _) = try await RemoteInstall.installAll(explicitRef: nil, defaultRef: "main", overwrite: false, to: dir, fetch: repo.fetch)
        guard case .failure(.alreadyInstalled("alpha")) = report.outcomes[0].result, case .success = report.outcomes[1].result else { Issue.record("結果が違う"); return }
    }
}

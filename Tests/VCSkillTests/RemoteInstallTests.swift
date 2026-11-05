import Foundation
import Testing
@testable import VCSkill

/// `vc skills install` の流れ（偽の通信）：版の決め方（既定のタグ・なければ main・`--ref`）と、名前ごとの結果。
@Suite struct RemoteInstallTests {
    private let skillMd = "---\nname: demo\ndescription: 説明\nallowed-commands: echo\n---\nRun it."

    /// タグ `v1.0.0` と `main` だけがある偽のリポジトリ。取得した URL を記録する。
    private final class Repo: @unchecked Sendable {
        private let lock = NSLock(); private(set) var refs: [String] = []
        let skillMd: String
        init(skillMd: String) { self.skillMd = skillMd }
        var fetch: RemoteSkills.Fetch {
            { [self] url in
                if url.host == "api.github.com" {
                    let ref = url.pathComponents.last ?? ""
                    lock.lock(); refs.append(ref); lock.unlock()
                    guard ["v1.0.0", "main"].contains(ref) else { return (Data(), 404) }
                    let tree: [[String: Any]] = [["path": ".voice-control/skills/demo/SKILL.md", "mode": "100644", "type": "blob", "size": 10]]
                    return (try JSONSerialization.data(withJSONObject: ["tree": tree]), 200)
                }
                return (Data(skillMd.utf8), 200)
            }
        }
    }

    private func destination() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ri-\(UUID().uuidString)") }

    @Test func theDefaultTagIsUsedWhenItExists() async throws {
        let repo = Repo(skillMd: skillMd)
        let report = try await RemoteInstall.install(names: ["demo"], explicitRef: nil, defaultRef: "v1.0.0", overwrite: false, to: destination(), fetch: repo.fetch)
        #expect(report.source == .init(ref: "v1.0.0", fellBackToMain: false))
        #expect(report.outcomes.count == 1 && (try? report.outcomes[0].result.get().name) == "demo")
        #expect(repo.refs == ["v1.0.0"])
    }

    @Test func aMissingDefaultTagFallsBackToMainButAnExplicitRefDoesNot() async throws {
        let repo = Repo(skillMd: skillMd)
        let listing = try await RemoteInstall.list(explicitRef: nil, defaultRef: "v9.9.9", fetch: repo.fetch)
        #expect(listing.source == .init(ref: "main", fellBackToMain: true) && listing.skills.map(\.name) == ["demo"])
        #expect(repo.refs == ["v9.9.9", "main"])
        await #expect(throws: RemoteSkills.Failure.refNotFound("v9.9.9")) { try await RemoteInstall.list(explicitRef: "v9.9.9", defaultRef: "v1.0.0", fetch: repo.fetch) }
    }

    /// 名前ごとの失敗は、ほかの名前を止めない（ない・同名）。
    @Test func failuresArePerNameAndDoNotStopTheOthers() async throws {
        let repo = Repo(skillMd: skillMd), dir = destination()
        _ = try await RemoteInstall.install(names: ["demo"], explicitRef: nil, defaultRef: "v1.0.0", overwrite: false, to: dir, fetch: repo.fetch)
        let report = try await RemoteInstall.install(names: ["demo", "nope"], explicitRef: nil, defaultRef: "v1.0.0", overwrite: false, to: dir, fetch: repo.fetch)
        guard case .failure(.alreadyInstalled("demo")) = report.outcomes[0].result, case .failure(.notFound("nope")) = report.outcomes[1].result else { Issue.record("結果が違う：\(report.outcomes)"); return }
        let forced = try await RemoteInstall.install(names: ["demo"], explicitRef: nil, defaultRef: "v1.0.0", overwrite: true, to: dir, fetch: repo.fetch)
        #expect((try? forced.outcomes[0].result.get().overwritten) == true)
    }
}

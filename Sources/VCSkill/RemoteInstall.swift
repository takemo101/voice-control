import Foundation
import VCCore

/// GitHub のスキルを、グローバルへインストールする流れ（`vc skills install`）：取得 → 読めるか・同名・リンクの検査 → 置く。表示は持たない（`vc` が決める）。
/// 版（タグ）は、既定では、入っている `vc` と同じ。そのタグがなければ（開発版など）、main から取る。`--ref` で指定したときは、なければ、失敗（main へは切り替えない）。
public enum RemoteInstall {
    /// どの版から取ったか。
    public struct Source: Sendable, Equatable {
        public let ref: String
        /// 既定のタグが、リポジトリになく、main から取った。
        public let fellBackToMain: Bool
    }

    /// インストールできるスキルの一覧。
    public struct Listing: Sendable {
        public let source: Source
        public let skills: [Skill]
        public let problems: [SkillProblem]
    }

    /// 名前ごとの結果。
    public struct Outcome: Sendable {
        public let name: String
        public let result: Result<SkillInstaller.Installed, SkillInstaller.Failure>
    }

    public struct Report: Sendable {
        public let source: Source
        public let outcomes: [Outcome]
    }

    /// 取得できるスキルの一覧（各スキルの `SKILL.md` だけを取る）。取得の失敗は `RemoteSkills.Failure`。
    public static func list(explicitRef: String?, defaultRef: String, fetch: RemoteSkills.Fetch = RemoteSkills.live) async throws -> Listing {
        let staging = Self.stagingDirectory()
        defer { cleanUp(staging) }
        let source = try await download(names: nil, explicitRef: explicitRef, defaultRef: defaultRef, into: staging, fetch: fetch)
        let loaded = SkillStore.load(directory: staging, scope: .project)
        return Listing(source: source, skills: loaded.skills, problems: loaded.problems)
    }

    /// `names` を、`destination`（既定は、グローバル）へ置く。名前ごとの失敗（ない・読めない・同名・リンク）は、`outcomes` に入る。取得そのものの失敗は、投げる（`RemoteSkills.Failure`）。
    public static func install(names: [String], explicitRef: String?, defaultRef: String, overwrite: Bool,
                               to destination: URL = VoiceControlHome.skillsDirectory, fetch: RemoteSkills.Fetch = RemoteSkills.live) async throws -> Report {
        let staging = Self.stagingDirectory()
        defer { cleanUp(staging) }
        let source = try await download(names: names, explicitRef: explicitRef, defaultRef: defaultRef, into: staging, fetch: fetch)
        let outcomes = names.map { name in
            do { return Outcome(name: name, result: .success(try SkillInstaller.install(name: name, from: staging, to: destination, overwrite: overwrite))) }
            catch let failure as SkillInstaller.Failure { return Outcome(name: name, result: .failure(failure)) }
            catch { return Outcome(name: name, result: .failure(.copyFailed(name: name, reason: error.localizedDescription))) }
        }
        return Report(source: source, outcomes: outcomes)
    }

    /// 取得する。既定の版が、リポジトリになければ、main から取る（`--ref` を指定したときは、切り替えない）。
    private static func download(names: [String]?, explicitRef: String?, defaultRef: String, into staging: URL, fetch: RemoteSkills.Fetch) async throws -> Source {
        if let explicitRef {
            try await RemoteSkills.download(names: names, ref: explicitRef, into: staging, fetch: fetch)
            return Source(ref: explicitRef, fellBackToMain: false)
        }
        do {
            try await RemoteSkills.download(names: names, ref: defaultRef, into: staging, fetch: fetch)
            return Source(ref: defaultRef, fellBackToMain: false)
        } catch RemoteSkills.Failure.refNotFound {
            try await RemoteSkills.download(names: names, ref: "main", into: staging, fetch: fetch)
            return Source(ref: "main", fellBackToMain: true)
        }
    }

    private static func stagingDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vc-skills-\(UUID().uuidString)")
    }

    private static func cleanUp(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)   // try?: 一時のディレクトリの後始末。失敗しても、結果は変わらない
    }
}

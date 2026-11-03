import Foundation

public enum SkillStore {
    public static let maxDescription = 200

    public struct Loaded: Sendable {
        public var skills: [Skill] = []
        public var problems: [SkillProblem] = []
        /// プロジェクトのスキルの置き場所（あれば）。
        public var projectDirectory: URL?
        /// プロジェクトのスキルが、未信頼のため、読み込まれていない件数（`vc skills trust` で信頼する）。
        public var untrustedProjectCount = 0
        /// プロジェクトのスキルが、同じ名前のグローバルのスキルを、上書きした名前。
        public var overridden: [String] = []
    }

    /// `directory/<name>/SKILL.md` を、すべて読む（名前順）。不正なものは、読み込まず、理由を返す。
    public static func load(directory: URL = VoiceControlHome.skillsDirectory, scope: Skill.Scope = .global) -> Loaded {
        var result = Loaded()
        let fm = FileManager.default
        // try?: スキルのディレクトリがなければ、スキルは 0 件（初めての使用で、普通の状態）
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return result }
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let dir = directory.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let file = dir.appendingPathComponent("SKILL.md")
            // SKILL.md が読めないものは、下で『読めなかったスキル』として理由を返す（握りつぶさない）
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                result.problems.append(SkillProblem(location: entry, reason: "SKILL.md が読めない"))
                continue
            }
            switch parse(text, directoryName: entry, file: file) {
            case .success(var skill): skill.scope = scope; result.skills.append(skill)
            case .failure(let error): result.problems.append(SkillProblem(location: entry, reason: error.reason))
            }
        }
        return result
    }

    /// グローバル（`~/.voice-control/skills`）と、プロジェクト（`<projectRoot>/.voice-control/skills`）のスキルを合わせて読む。
    /// - 同じ名前なら、**プロジェクトが、グローバルを上書きする**。
    /// - プロジェクトのスキルは、リポジトリなど、外から来るものなので、**信頼したプロジェクトだけ**読み込む（`Settings.trustedProjects`）。未信頼なら、件数だけを返す。
    /// - プロジェクトの置き場所が、グローバルと同じ場所（ホームで起動したとき）なら、二重に読まない。
    ///
    /// 同じ名前（`default`）のスキルが、どちらにもなければ、組み込みの既定スキル（`DefaultSkill`）を足す。
    public static func loadAll(projectRoot: URL?, settings: Settings, globalDirectory: URL = VoiceControlHome.skillsDirectory) -> Loaded {
        var result = loadUserSkills(projectRoot: projectRoot, settings: settings, globalDirectory: globalDirectory)
        if !result.skills.contains(where: { $0.name == DefaultSkill.name }) {
            result.skills.append(DefaultSkill.skill)
            result.skills.sort { $0.name < $1.name }
        }
        return result
    }

    private static func loadUserSkills(projectRoot: URL?, settings: Settings, globalDirectory: URL) -> Loaded {
        var result = load(directory: globalDirectory)
        guard let projectRoot else { return result }
        let projectDirectory = VoiceControlHome.projectSkillsDirectory(root: projectRoot)
        func real(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        guard real(projectDirectory) != real(globalDirectory), FileManager.default.fileExists(atPath: projectDirectory.path) else { return result }
        result.projectDirectory = projectDirectory

        let project = load(directory: projectDirectory, scope: .project)
        guard settings.isTrusted(project: projectRoot) else {
            result.untrustedProjectCount = project.skills.count + project.problems.count
            return result
        }
        result.problems += project.problems.map { SkillProblem(location: "プロジェクト: \($0.location)", reason: $0.reason) }
        for skill in project.skills {
            if let index = result.skills.firstIndex(where: { $0.name == skill.name }) {
                result.overridden.append(skill.name)
                result.skills[index] = skill
            } else {
                result.skills.append(skill)
            }
        }
        result.skills.sort { $0.name < $1.name }
        return result
    }
}

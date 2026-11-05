import Foundation

/// GitHub の公開リポジトリから、スキル（`.voice-control/skills/<name>`）を取得する（`vc skills install`）。
/// 一覧は、Git のツリー 1 回（`git/trees/<ref>?recursive=1`）で取り、ファイルは `raw.githubusercontent.com` から取る（API の回数制限を、ほぼ使わない）。
/// 取得したものは、一時のディレクトリに置くだけ（グローバルへ置く判断は `SkillInstaller`）。送るのは、リポジトリ・版・ファイルの場所だけ（音声・画面の内容は、関係しない）。
public enum RemoteSkills {
    public static let repository = "takemo101/voice-control"
    static let skillsPath = ".voice-control/skills/"
    /// 1 つのスキルの上限（外から来るものなので、異常に大きいものは、取らない）。
    static let maxFiles = 50
    static let maxFileBytes = 1_000_000

    public enum Failure: Error, Equatable {
        /// 通信できない・サーバーが、エラーを返した（理由）。
        case network(String)
        /// その版（タグ・ブランチ）が、リポジトリにない。
        case refNotFound(String)
        /// 想定していない内容（形式・大きさ）。
        case unexpected(String)
        /// シンボリックリンクを含む。
        case containsSymlink(name: String, path: String)
    }

    /// 1 回の取得（URL → 状態コードと本文）。テストで、差し替える。
    public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

    public static let live: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("voice-control", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// `names` のスキル（ディレクトリごと）を、`staging/<name>/…` へ取得する。`nil` なら、すべてのスキルの `SKILL.md` だけ（一覧用）。
    /// リポジトリにない名前・スキルの名前として使えない名前は、取得しない（`SkillInstaller` が、「ない」と答える）。
    public static func download(names: [String]?, ref: String, repository: String = repository, into staging: URL, fetch: Fetch = live) async throws {
        let entries = try await tree(ref: ref, repository: repository, fetch: fetch)
        let wanted = names.map(Set.init)
        let fm = FileManager.default
        var perSkill: [String: [Entry]] = [:]
        for entry in entries { perSkill[entry.skill, default: []].append(entry) }
        for (name, files) in perSkill.sorted(by: { $0.key < $1.key }) {
            guard name.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil, files.contains(where: { $0.rest == "SKILL.md" }) else { continue }
            if let wanted, !wanted.contains(name) { continue }
            if let link = files.first(where: { $0.mode == "120000" }) { throw Failure.containsSymlink(name: name, path: link.rest) }
            let targets = wanted == nil ? files.filter { $0.rest == "SKILL.md" } : files.filter { $0.type == "blob" && $0.mode != "160000" }
            guard targets.count <= maxFiles, targets.allSatisfy({ $0.size <= maxFileBytes }) else { throw Failure.unexpected("スキル「\(name)」が大きすぎる（\(maxFiles) ファイル・1 ファイル \(maxFileBytes / 1000) KB まで）") }
            for file in targets {
                let url = try rawURL(repository: repository, ref: ref, path: file.path)
                let (data, status) = try await get(url, fetch: fetch)
                guard status == 200 else { throw Failure.network("\(file.path)：HTTP \(status)") }
                let destination = staging.appendingPathComponent(name).appendingPathComponent(file.rest)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination)
                try fm.setAttributes([.posixPermissions: file.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: destination.path)
            }
        }
    }

    /// リポジトリのツリーの、`.voice-control/skills/<name>/…` の項目。
    struct Entry { let path: String; let skill: String; let rest: String; let mode: String; let type: String; let size: Int }

    static func tree(ref: String, repository: String, fetch: Fetch) async throws -> [Entry] {
        guard let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              let url = URL(string: "https://api.github.com/repos/\(repository)/git/trees/\(encodedRef)?recursive=1") else { throw Failure.unexpected("版の名前が使えない：\(ref)") }
        let (data, status) = try await get(url, fetch: fetch)
        if status == 404 { throw Failure.refNotFound(ref) }
        guard status == 200 else { throw Failure.network("GitHub：HTTP \(status)") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tree = root["tree"] as? [[String: Any]] else { throw Failure.unexpected("GitHub の応答を読めない") }   // try?: 読めなければ、下の失敗として返す
        if root["truncated"] as? Bool == true { throw Failure.unexpected("リポジトリが大きすぎて、一覧を取れない") }
        return tree.compactMap { item in
            guard let path = item["path"] as? String, path.hasPrefix(skillsPath) else { return nil }
            let parts = path.dropFirst(skillsPath.count).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
            return Entry(path: path, skill: parts[0], rest: parts[1], mode: (item["mode"] as? String) ?? "", type: (item["type"] as? String) ?? "", size: (item["size"] as? Int) ?? 0)
        }
    }

    private static func rawURL(repository: String, ref: String, path: String) throws -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: allowed) ?? ref
        let encodedPath = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/")
        guard let url = URL(string: "https://raw.githubusercontent.com/\(repository)/\(encodedRef)/\(encodedPath)") else { throw Failure.unexpected("ファイルの場所が使えない：\(path)") }
        return url
    }

    private static func get(_ url: URL, fetch: Fetch) async throws -> (data: Data, status: Int) {
        do { return try await fetch(url) } catch { throw Failure.network(error.localizedDescription) }
    }
}

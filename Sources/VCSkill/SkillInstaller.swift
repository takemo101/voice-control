import Foundation

/// 取得したスキル（`RemoteSkills` が置いた一時のディレクトリ）を、グローバル（`~/.voice-control/skills`）へ置く（`vc skills install`）。
/// スキルのディレクトリごと（SKILL.md と同梱のスクリプト）。読めないスキル・シンボリックリンクを含むスキルは、コピーしない。
public enum SkillInstaller {
    public enum Failure: Error, Equatable {
        /// 取得したものの中に、その名前の読めるスキルがない。
        case notFound(String)
        /// SKILL.md が不正で、読めない（理由）。
        case unreadable(name: String, reason: String)
        /// 置き先に、すでにある（上書きは、`overwrite: true`）。
        case alreadyInstalled(String)
        /// シンボリックリンクを含む（リンク先が、コピー先で意味を持たなくなる・外のファイルを指せるので、コピーしない）。
        case containsSymlink(name: String, path: String)
        case copyFailed(name: String, reason: String)
    }

    public struct Installed: Sendable, Equatable {
        public let name: String
        /// グローバルに置いたあと、言語モデルが実行してよいコマンド（置き場所の絶対パスに置き換え済み）。
        public let allowedCommands: [String]
        public let confirm: Bool
        public let destination: URL
        public let overwritten: Bool
        /// SKILL.md が、プロジェクトの相対パス（`.voice-control/skills/…`）でスクリプトを指している：グローバルでは、起動した場所によって、見つからない（`${SKILL_DIR}` に直す）。
        public let usesProjectRelativePath: Bool
    }

    /// `source/<name>` を `destination/<name>` へコピーする。置き先に同名があれば、`overwrite` のときだけ、置き換える（古いファイルは、残らない）。
    public static func install(name: String, from source: URL, to destination: URL, overwrite: Bool) throws -> Installed {
        let fm = FileManager.default
        // 名前は、読み込めたスキルの名前だけ通す（`../x` のような値で、ほかの場所を指せない）
        let loaded = SkillStore.load(directory: source, scope: .project)
        if let problem = loaded.problems.first(where: { $0.location == name }) { throw Failure.unreadable(name: name, reason: problem.reason) }
        guard let skill = loaded.skills.first(where: { $0.name == name }) else { throw Failure.notFound(name) }
        let sourceDirectory = skill.file.deletingLastPathComponent()
        if let link = firstSymlink(in: sourceDirectory) { throw Failure.containsSymlink(name: name, path: link) }

        let target = destination.appendingPathComponent(name)
        let exists = (try? fm.attributesOfItem(atPath: target.path)) != nil   // try?: 無ければ、なし（リンク切れも「ある」と数える）
        if exists && !overwrite { throw Failure.alreadyInstalled(name) }
        let rawText = (try? String(contentsOf: skill.file, encoding: .utf8)) ?? ""   // try?: 読み込めた直後のファイル。読めなければ、警告が出ないだけ

        // 一時の場所へ全部コピーしてから、置く（途中で失敗しても、置き先は、壊れない。`.` で始まるので、スキルとして読まれない）
        let staging = destination.appendingPathComponent(".install-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.copyItem(at: sourceDirectory, to: staging)
            if exists { _ = try fm.replaceItemAt(target, withItemAt: staging) } else { try fm.moveItem(at: staging, to: target) }
        } catch {
            try? fm.removeItem(at: staging)   // try?: 後始末。元の失敗を、返す
            throw Failure.copyFailed(name: name, reason: error.localizedDescription)
        }

        // 置いた場所での姿（`${SKILL_DIR}` は、置き先の絶対パスになる）
        let installed = SkillStore.load(directory: destination).skills.first { $0.name == name }
        return Installed(name: name, allowedCommands: installed?.allowedCommands ?? skill.allowedCommands, confirm: skill.confirm,
                         destination: target, overwritten: exists, usesProjectRelativePath: rawText.contains(".voice-control/skills/"))
    }

    /// ディレクトリの中（自身を含む）の、最初のシンボリックリンク（ディレクトリからの相対パス）。
    static func firstSymlink(in directory: URL) -> String? {
        let fm = FileManager.default
        func isLink(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink }   // try?: 調べられなければ、リンクではない扱い（次のコピーが、失敗として返す）
        if isLink(directory.path) { return "." }
        guard let walker = fm.enumerator(atPath: directory.path) else { return nil }
        for case let relative as String in walker where isLink(directory.appendingPathComponent(relative).path) { return relative }
        return nil
    }
}

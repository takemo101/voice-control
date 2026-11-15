import Foundation

/// 発話の中の、ファイル名（拡張子つき。`note.txt`）：「ファイルの依頼か」「どのファイルか」の判定が、同じ決まりを使う。
enum FileNames {
    private static let regex = try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-][A-Za-z0-9_.\-]*\.(?:txt|md|csv|json|log|swift|py|js|ts|html|yaml|yml|toml)\b"#, options: [.caseInsensitive])   // 定数の正規表現

    /// 発話に出てくる、ファイル名（出てきた順）。
    static func mentioned(in request: String) -> [String] {
        regex.matches(in: request, range: NSRange(request.startIndex..., in: request)).compactMap { Range($0.range, in: request).map { String(request[$0]) } }
    }

    static func contains(in request: String) -> Bool { !mentioned(in: request).isEmpty }
}

/// 作業フォルダの中だけを読む。`..`・絶対パス・シンボリックリンクで外へ出る道は、塞ぐ。
struct FolderReader: Sendable {
    let root: URL
    static let maxCharacters = 3500
    static let maxEntries = 60

    enum Failure: Error, CustomStringConvertible, Equatable {
        case outside, notFound, notText, tooLarge, isDirectory
        var description: String {
            switch self {
            case .outside: return "That path is outside the working folder."
            case .notFound: return "Not found."
            case .notText: return "Not a UTF-8 text file."
            case .tooLarge: return "File is too large."
            case .isDirectory: return "That path is a folder."
            }
        }
    }

    /// `path`（作業フォルダからの相対）を、実体のパスにして、フォルダの中か確かめる。
    func resolve(_ path: String) throws -> URL {
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { throw Failure.outside }
        let target = (trimmed.isEmpty || trimmed == "." ? realRoot : realRoot.appendingPathComponent(trimmed)).resolvingSymlinksInPath().standardizedFileURL
        guard target.path == realRoot.path || target.path.hasPrefix(realRoot.path + "/") else { throw Failure.outside }
        guard FileManager.default.fileExists(atPath: target.path) else { throw Failure.notFound }
        return target
    }

    /// 書き込む先：作業フォルダの中だけ（`..`・絶対パス・外へのシンボリックリンクは不可）。まだないファイルでもよい（途中のフォルダは、書くときに作る）。
    /// 戻り値の `exists`：すでにあるファイルか（上書きの確認に使う）。
    func resolveForWrite(_ path: String) throws -> (url: URL, exists: Bool) {
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { throw Failure.outside }
        let target = realRoot.appendingPathComponent(trimmed).standardizedFileURL
        guard target.path.hasPrefix(realRoot.path + "/") else { throw Failure.outside }
        // いちばん近い、すでにある親を、実体にして、フォルダの中か確かめる（途中が、外へのシンボリックリンクなら、不可）
        var ancestor = target.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path.count > realRoot.path.count { ancestor = ancestor.deletingLastPathComponent() }
        let realAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
        guard realAncestor.path == realRoot.path || realAncestor.path.hasPrefix(realRoot.path + "/") else { throw Failure.outside }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
        if exists {
            guard !isDirectory.boolValue else { throw Failure.isDirectory }
            let realTarget = target.resolvingSymlinksInPath().standardizedFileURL
            guard realTarget.path.hasPrefix(realRoot.path + "/") else { throw Failure.outside }
        }
        return (target, exists)
    }

    static let maxWriteCharacters = 200_000

    /// 書く（途中のフォルダは、作る）。
    func write(_ text: String, to url: URL) throws {
        guard text.count <= Self.maxWriteCharacters else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func list(_ path: String) throws -> String {
        let directory = try resolve(path)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
        guard !names.isEmpty else { return "(empty)" }
        let shown = names.prefix(Self.maxEntries).map { name -> String in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? name + "/" : name
        }
        return shown.joined(separator: "\n") + (names.count > Self.maxEntries ? "\n…(\(names.count - Self.maxEntries) more)" : "")
    }

    func read(_ path: String) throws -> String {
        let file = try resolve(path)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= 2_000_000 else { throw Failure.tooLarge }
        guard let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) else { throw Failure.notText }
        return WebText.clip(text, Self.maxCharacters)
    }
}

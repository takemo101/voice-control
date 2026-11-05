import Foundation
import VCCore

/// ファイルの検索（`vc find`）：名前・場所・種類・期間で、候補を集める。読み取りだけ（開く・動かす・消すは、しない）。
/// Spotlight（`mdfind`）で、速く探す。Spotlight にないもの（できたばかり・インデックスのない場所）は、フォルダをたどって探す（時間と件数に上限）。
public struct FileQuery: Sendable, Equatable {
    /// ファイル名に含まれる文字（空白で区切った、すべてを含む）。
    public var name: String
    public var directory: URL
    /// 拡張子（`pdf`）。
    public var ext: String?
    /// 更新が、この秒数より新しい。
    public var since: TimeInterval?
    /// 新しさの順で、古いものを先にする（既定は、新しいものが先）。
    public var oldestFirst: Bool
    public var limit: Int

    public init(name: String = "", directory: URL, ext: String? = nil, since: TimeInterval? = nil, oldestFirst: Bool = false, limit: Int = 30) {
        self.name = name; self.directory = directory; self.ext = ext; self.since = since; self.oldestFirst = oldestFirst; self.limit = limit
    }

    var tokens: [String] { name.split(whereSeparator: \.isWhitespace).map(String.init).map(FileSearch.sanitized).filter { !$0.isEmpty } }
}

public struct FileCandidate: Sendable, Equatable {
    public let path: String
    public let modified: Date?

    public init(path: String, modified: Date?) { self.path = path; self.modified = modified }

    public var name: String { (path as NSString).lastPathComponent }
    public var ext: String { (path as NSString).pathExtension.lowercased() }

    /// 選択（Tiny-Jev）に渡す、短い 1 行：「名前 — フォルダ（種類・日付）」。フォルダは、末尾の 2 つ。
    public func line(now: Date = Date(), calendar: Calendar = .current) -> String {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).pathComponents.suffix(2).filter { $0 != "/" }.joined(separator: "/")
        var parts = [ext.isEmpty ? "種類なし" : ext]
        if let modified {
            let sameYear = calendar.component(.year, from: modified) == calendar.component(.year, from: now)
            let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = sameYear ? "MM/dd" : "yyyy/MM/dd"
            parts.append(f.string(from: modified))
        }
        return "\(name) — \(parent)（\(parts.joined(separator: "・"))）"
    }
}

public enum FileSearch {
    public enum ArgumentError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)
        case needsCondition
        case invalid(String)
        public var description: String {
            switch self {
            case .unknown(let a): return "知らないオプション: \(a)（--name・--in・--ext・--since・--limit・--oldest）"
            case .missingValue(let a): return "\(a) に、値がありません"
            case .needsCondition: return "--name・--ext・--since のどれかが要ります"
            case .invalid(let why): return why
            }
        }
    }

    /// Spotlight への問い合わせ（探す場所・条件 → パスの並び）。テストで、差し替える。
    public typealias Spotlight = @Sendable (_ directory: String, _ query: String) -> [String]

    public static let live: Spotlight = { directory, query in
        let result = CommandRunner.run(argv: ["mdfind", "-onlyin", directory, query], timeout: 10)
        // mdfind は、警告（[UserQueryParser] …）を、同じ出力に混ぜる：パスの行だけ
        return result.output.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix("/") }
    }

    // MARK: 引数

    /// `--name <文字> --in <フォルダ> --ext <拡張子> --since <7d|2w|1m|12h> --limit <件数> --oldest`。
    public static func parse(_ arguments: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> FileQuery {
        var query = FileQuery(directory: home)
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < arguments.count else { throw ArgumentError.missingValue(flag) }
            return arguments[i]
        }
        while i < arguments.count {
            let flag = arguments[i]
            // 言語モデルが、書式の説明の単語（`period`・`type`・`folder`…）を、そのまま値にすることがある：その値は、指定がなかったものとして、読み飛ばす（測定：Apple のモデル）
            if ["--in", "--ext", "--since"].contains(flag), i + 1 < arguments.count, placeholders.contains(arguments[i + 1].lowercased()) { i += 2; continue }
            switch flag {
            case "--name": query.name = try value(flag)
            case "--in":
                let path = (try value(flag) as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ArgumentError.invalid("フォルダがありません: \(path)") }
                query.directory = URL(fileURLWithPath: path)
            case "--ext": query.ext = try value(flag).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            case "--since":
                let text = try value(flag)
                guard let seconds = parseSince(text) else { throw ArgumentError.invalid("--since は、7d・2w・1m・12h の形です: \(text)") }
                query.since = seconds
            case "--limit":
                guard let n = Int(try value(flag)), (1...200).contains(n) else { throw ArgumentError.invalid("--limit は、1〜200 の数です") }
                query.limit = n
            case "--oldest": query.oldestFirst = true
            default: throw ArgumentError.unknown(flag)
            }
            i += 1
        }
        guard !query.tokens.isEmpty || query.ext?.isEmpty == false || query.since != nil else { throw ArgumentError.needsCondition }
        return query
    }

    static let placeholders: Set<String> = ["period", "type", "folder", "words", "ext", "extension", "name", "dir", "directory", "path"]

    /// `7d`（日）・`2w`（週）・`1m`（30 日）・`12h`（時間）。
    public static func parseSince(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let n = Double(text.dropLast()), n > 0 else { return nil }
        switch unit {
        case "h": return n * 3600
        case "d": return n * 86_400
        case "w": return n * 7 * 86_400
        case "m": return n * 30 * 86_400
        default: return nil
        }
    }

    // MARK: 検索

    /// Spotlight の問い合わせの文字。名前は、大文字小文字・濁点を区別しない（`cd`）。引用符・`\`・`*` は、取り除く（問い合わせを、壊させない）。
    public static func spotlightQuery(for query: FileQuery) -> String {
        var terms = query.tokens.map { "kMDItemFSName == \"*\($0)*\"cd" }
        if let ext = query.ext, !ext.isEmpty { terms.append("kMDItemFSName == \"*.\(sanitized(ext))\"c") }
        if let since = query.since { terms.append("kMDItemFSContentChangeDate >= $time.now(-\(Int(since)))") }
        return terms.joined(separator: " && ")
    }

    static func sanitized(_ text: String) -> String { text.filter { !"\"\\*'".contains($0) } }

    /// 候補にしない場所：隠しフォルダ・ライブラリ・キャッシュ・アプリの中・依存のフォルダ。
    static let excludedComponents: Set<String> = ["Library", "node_modules", "Caches", "__pycache__", ".Trash", "Pods", "DerivedData"]

    public static func isExcluded(_ path: String) -> Bool {
        for component in path.split(separator: "/") {
            if component.hasPrefix(".") || excludedComponents.contains(String(component)) || component.hasSuffix(".app") { return true }
        }
        return false
    }

    /// 候補（`limit` 件まで）。名前の一致（そのまま・前方・含む）→ 新しさ（`oldestFirst` なら、古さ）の順。Spotlight が 0 件なら、フォルダをたどって探す。
    public static func search(_ query: FileQuery, spotlight: Spotlight = live, now: Date = Date(), walkTimeout: TimeInterval = 4) -> [FileCandidate] {
        var found = spotlight(query.directory.path, spotlightQuery(for: query)).filter { !isExcluded($0) }.compactMap(candidate(at:))
        if found.isEmpty { found = walk(query, now: now, timeout: walkTimeout) }
        let tokens = query.tokens.map { $0.lowercased() }
        func relevance(_ c: FileCandidate) -> Int {
            let base = ((c.name as NSString).deletingPathExtension).lowercased()
            if tokens.joined(separator: " ") == base || tokens.count == 1 && tokens[0] == base { return 3 }
            if let first = tokens.first, base.hasPrefix(first) { return 2 }
            return tokens.isEmpty ? 0 : 1
        }
        let sorted = found.sorted { a, b in
            let (ra, rb) = (relevance(a), relevance(b))
            if ra != rb { return ra > rb }
            let (da, db) = (a.modified ?? .distantPast, b.modified ?? .distantPast)
            return query.oldestFirst ? da < db : da > db
        }
        return Array(sorted.prefix(query.limit))
    }

    /// 普通のファイルだけ（フォルダ・消えたものは、除く）。
    private static func candidate(at path: String) -> FileCandidate? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true else { return nil }   // try?: 読めない・消えたファイルは、候補にしない
        return FileCandidate(path: path, modified: values.contentModificationDate)
    }

    /// フォルダをたどる探し方（Spotlight が見つけないとき）。時間（`timeout`）と件数（20 万）に、上限。
    static func walk(_ query: FileQuery, now: Date, timeout: TimeInterval) -> [FileCandidate] {
        let deadline = Date().addingTimeInterval(timeout)
        let tokens = query.tokens.map { $0.lowercased() }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: query.directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [FileCandidate] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 200_000 || (visited % 500 == 0 && Date() > deadline) { break }
            let values = try? url.resourceValues(forKeys: Set(keys))   // try?: 読めないものは、飛ばす
            if values?.isDirectory == true {
                if excludedComponents.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let name = url.lastPathComponent.lowercased()
            guard tokens.allSatisfy({ name.contains($0) }) else { continue }
            if let ext = query.ext, !ext.isEmpty, url.pathExtension.lowercased() != ext { continue }
            if let since = query.since, let modified = values?.contentModificationDate, modified < now.addingTimeInterval(-since) { continue }
            out.append(FileCandidate(path: url.path, modified: values?.contentModificationDate))
        }
        return out
    }

    // MARK: 表示

    /// 言語モデル・画面へ返す文：番号つきの候補の行と、その下に、フルパス（開くのに使う）。
    public static func render(_ candidates: [FileCandidate], now: Date = Date()) -> String {
        guard !candidates.isEmpty else { return "no files found. Try another name, folder or period." }
        let lines = candidates.enumerated().map { "\($0.offset + 1). \($0.element.line(now: now))\n   \($0.element.path)" }
        return "found \(candidates.count) file(s):\n" + lines.joined(separator: "\n")
    }
}

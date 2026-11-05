import Foundation
import Testing
@testable import VCSkill

/// ファイル検索（`vc find`）：引数・Spotlight の問い合わせ・候補の絞り込みと並び・フォルダをたどる探し方（Spotlight が見つけないとき）。
@Suite struct FileSearchTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func file(_ root: URL, _ relative: String, age: TimeInterval = 0) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url.path
    }

    @Test func argumentsAreParsedAndAConditionIsRequired() throws {
        let home = URL(fileURLWithPath: "/tmp")
        let q = try FileSearch.parse(["--name", "請求書 10月", "--in", "/tmp", "--ext", ".PDF", "--since", "2w", "--limit", "5", "--oldest"], home: home)
        #expect(q.name == "請求書 10月" && q.directory.path == "/tmp" && q.ext == "pdf" && q.since == 14 * 86_400 && q.limit == 5 && q.oldestFirst)
        #expect(throws: FileSearch.ArgumentError.needsCondition) { try FileSearch.parse([], home: home) }
        #expect(throws: FileSearch.ArgumentError.unknown("--exec")) { try FileSearch.parse(["--name", "a", "--exec", "rm"], home: home) }
        #expect(throws: FileSearch.ArgumentError.missingValue("--name")) { try FileSearch.parse(["--name"], home: home) }
        #expect(throws: FileSearch.ArgumentError.self) { try FileSearch.parse(["--name", "a", "--in", "/no/such/dir"], home: home) }
        #expect(throws: FileSearch.ArgumentError.self) { try FileSearch.parse(["--name", "a", "--since", "soon"], home: home) }
        #expect(throws: FileSearch.ArgumentError.self) { try FileSearch.parse(["--name", "a", "--limit", "9999"], home: home) }
    }

    /// 言語モデルが、書式の説明の単語を、そのまま値にしても（`--since period`）、指定がなかったものとして読み飛ばす。
    @Test func placeholderWordsAsValuesAreIgnored() throws {
        let q = try FileSearch.parse(["--name", "見積書", "--in", "folder", "--ext", "type", "--since", "period"], home: URL(fileURLWithPath: "/tmp"))
        #expect(q.name == "見積書" && q.directory.path == "/tmp" && q.ext == nil && q.since == nil)
    }

    @Test func sinceUnits() {
        #expect(FileSearch.parseSince("12h") == 43_200 && FileSearch.parseSince("7d") == 604_800 && FileSearch.parseSince("1m") == 2_592_000)
        #expect(FileSearch.parseSince("0d") == nil && FileSearch.parseSince("d") == nil && FileSearch.parseSince("3y") == nil)
    }

    /// 名前に、引用符・`\`・`*` があっても、問い合わせを壊さない（取り除く）。
    @Test func theSpotlightQueryHasOnePartPerWordAndCannotBeBroken() {
        let q = FileQuery(name: "請求書 \"10月\" *", directory: URL(fileURLWithPath: "/tmp"), ext: "pdf", since: 3600)
        #expect(FileSearch.spotlightQuery(for: q) == "kMDItemFSName == \"*請求書*\"cd && kMDItemFSName == \"*10月*\"cd && kMDItemFSName == \"*.pdf\"c && kMDItemFSContentChangeDate >= $time.now(-3600)")
    }

    @Test func hiddenLibraryCacheAndAppInternalsAreExcluded() {
        for path in ["/Users/a/Library/Caches/x.pdf", "/Users/a/.git/config", "/Users/a/proj/node_modules/p/x.js", "/Applications/Foo.app/Contents/x.plist"] { #expect(FileSearch.isExcluded(path), "\(path)") }
        #expect(!FileSearch.isExcluded("/Users/a/Documents/請求書.pdf"))
    }

    @Test func exactNamesFirstThenPrefixThenNewestAndTheLimitApplies() throws {
        let root = try temp()
        let old = try file(root, "請求書.pdf", age: 90 * 86_400)
        let newSub = try file(root, "請求書_10月.pdf", age: 5 * 86_400)
        let newer = try file(root, "旧請求書.pdf", age: 1 * 86_400)
        _ = try file(root, ".hidden/請求書.pdf")
        let found = FileSearch.search(FileQuery(name: "請求書", directory: root, limit: 10), spotlight: { _, _ in [old, newSub, newer, root.appendingPathComponent(".hidden/請求書.pdf").path, root.path] })
        #expect(found.map(\.path) == [old, newSub, newer])   // 一致（そのまま）→ 前方 → 含む。隠し・フォルダは、除く
        #expect(FileSearch.search(FileQuery(name: "請求書", directory: root, limit: 2), spotlight: { _, _ in [old, newSub, newer] }).count == 2)
        // 新しさの向きは、同じ一致の中だけ：同じ名前の 2 つで、新しいものが先（既定）・古いものが先（--oldest）
        let a = try file(root, "a/メモ.txt", age: 10 * 86_400), b = try file(root, "b/メモ.txt", age: 1 * 86_400)
        #expect(FileSearch.search(FileQuery(name: "メモ", directory: root), spotlight: { _, _ in [a, b] }).map(\.path) == [b, a])
        #expect(FileSearch.search(FileQuery(name: "メモ", directory: root, oldestFirst: true), spotlight: { _, _ in [a, b] }).map(\.path) == [a, b])
    }

    /// Spotlight が見つけないとき（できたばかりのファイル）は、フォルダをたどって探す。
    @Test func whenSpotlightFindsNothingTheFolderIsWalked() throws {
        let root = try temp()
        let hit = try file(root, "docs/見積書_最新.pdf")
        _ = try file(root, "docs/メモ.txt")
        _ = try file(root, "node_modules/p/見積書.pdf")
        _ = try file(root, "docs/見積書_古い.pdf", age: 400 * 86_400)
        let found = FileSearch.search(FileQuery(name: "見積書", directory: root, ext: "pdf", since: 30 * 86_400), spotlight: { _, _ in [] })
        #expect(found.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path } == [URL(fileURLWithPath: hit).resolvingSymlinksInPath().path])   // 依存のフォルダ・古いファイル・別の拡張子は、除く（/var と /private/var は、同じ場所）
    }

    @Test func aCandidateLineIsShortAndShowsFolderKindAndDate() {
        let now = Date(timeIntervalSince1970: 1_730_800_000)   // 2024-11-05
        let c = FileCandidate(path: "/Users/a/Documents/経理/2024/請求書_10月.pdf", modified: Date(timeIntervalSince1970: 1_730_100_000))
        #expect(c.line(now: now, calendar: Calendar(identifier: .gregorian)).hasPrefix("請求書_10月.pdf — 経理/2024（pdf・"))
        #expect(FileSearch.render([], now: now).hasPrefix("no files found"))
        let text = FileSearch.render([c], now: now)
        #expect(text.hasPrefix("found 1 file(s):\n1. 請求書_10月.pdf") && text.hasSuffix("\n   /Users/a/Documents/経理/2024/請求書_10月.pdf"))
    }
}

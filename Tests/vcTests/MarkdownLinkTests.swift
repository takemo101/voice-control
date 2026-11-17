import Foundation
import Testing
@testable import vc

/// Markdown のリンク：作業フォルダからの相対を、実際の場所にする・開いてよい場所の、実在するファイルだけ・開き方。
@Suite struct MarkdownLinkTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vc-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "x".write(to: url.appendingPathComponent("security-news-detail.md"), atomically: true, encoding: .utf8)
        try "x".write(to: url.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        return url
    }

    @Test func aRelativeLinkToACreatedFileResolvesInsideTheChatFolder() throws {
        let base = try folder(); defer { try? FileManager.default.removeItem(at: base) }
        // 利用者が押して、Finder が -50 を出した、実際のリンクの形（相対・スキームなし）
        let resolved = MarkdownLink.resolve(URL(string: "security-news-detail.md")!, base: base)
        #expect(resolved?.lastPathComponent == "security-news-detail.md" && resolved?.isFileURL == true)
        #expect(MarkdownLink.resolve(URL(string: "./security-news-detail.md")!, base: base) != nil)
        #expect(MarkdownLink.resolve(URL(fileURLWithPath: base.appendingPathComponent("security-news-detail.md").path), base: base) != nil)   // 絶対・file://
    }

    @Test func linksToMissingFilesOrOutsideTheReadablePlacesOrOfOtherSchemesAreNotLinks() throws {
        let base = try folder(); defer { try? FileManager.default.removeItem(at: base) }
        #expect(MarkdownLink.resolve(URL(string: "nothing.md")!, base: base) == nil)               // ない
        #expect(MarkdownLink.resolve(URL(string: "../../../../etc/hosts")!, base: base) == nil)    // 外へ出る
        #expect(MarkdownLink.resolve(URL(fileURLWithPath: "/etc/hosts"), base: base) == nil)       // 読んでよい場所の外
        #expect(MarkdownLink.resolve(URL(string: "security-news-detail.md")!, base: nil) == nil)  // 基準がなければ、相対は、解けない
        for bad in ["javascript:alert(1)", "x-apple.systempreferences:com.apple.preference.security", "ssh://host", "tel:123"] { #expect(MarkdownLink.resolve(URL(string: bad)!, base: base) == nil, "\(bad)") }
        for good in ["https://example.com/a", "http://example.com", "mailto:a@example.com"] { #expect(MarkdownLink.resolve(URL(string: good)!, base: base)?.absoluteString == good) }
        // リンクで、外へ出る（シンボリックリンク）
        let link = base.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(MarkdownLink.resolve(URL(string: "escape.md")!, base: base) == nil)
    }

    @Test func documentsAndImagesOpenAndEverythingElseIsOnlyRevealedInFinder() {
        #expect(MarkdownLink.action(for: URL(fileURLWithPath: "/w/a.md")) == .open && MarkdownLink.action(for: URL(fileURLWithPath: "/w/p.PNG")) == .open)
        #expect(MarkdownLink.action(for: URL(fileURLWithPath: "/w/run.sh")) == .reveal)          // スクリプト：開くと、実行されうる
        #expect(MarkdownLink.action(for: URL(fileURLWithPath: "/w/Evil.app")) == .reveal && MarkdownLink.action(for: URL(fileURLWithPath: "/w/x.command")) == .reveal)
        #expect(MarkdownLink.action(for: URL(fileURLWithPath: "/w/a.md"), isDirectory: true) == .reveal)
        #expect(MarkdownLink.action(for: URL(fileURLWithPath: "/w/a.md"), isExecutable: true) == .reveal)
        #expect(MarkdownLink.action(for: URL(fileURLWithPath: "/w/noext")) == .reveal)
    }

    /// 実際の描画：相対のリンクは、実際のファイルの場所のリンクに。ないファイルは、リンクにならない。
    @MainActor @Test func renderedRelativeLinksPointAtTheRealFileAndMissingOnesAreNotLinks() throws {
        let base = try folder(); defer { try? FileManager.default.removeItem(at: base) }
        let text = MarkdownRenderer.render("作りました：[security-news-detail.md](security-news-detail.md) と [無い](nothing.md)", imageBase: base)
        var links: [String: URL] = [:]
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let url = value as? URL { links[(text.string as NSString).substring(with: range)] = url }
        }
        #expect(links["security-news-detail.md"]?.isFileURL == true && links["security-news-detail.md"]?.lastPathComponent == "security-news-detail.md")
        #expect(links["無い"] == nil)
    }
}


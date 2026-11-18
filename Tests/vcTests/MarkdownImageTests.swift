import AppKit
import Foundation
import Testing
@testable import vc
import VCCore

/// Markdown の画像：この Mac の中の、読んでよい場所のファイルだけ、文章の中に出す（ネットワークの画像・場所の外・リンク越しの外は、リンクのまま）。
@MainActor @Suite struct MarkdownImageTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vc-mdimg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writePNG(_ url: URL, width: Int = 40, height: Int = 20) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    @Test func onlyReadableLocalImageFilesAreFound() throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        try writePNG(folder.appendingPathComponent("a.png"))
        // 絶対パス・file URL・作業フォルダからの相対
        #expect(MarkdownImage.file(for: URL(string: "file://\(folder.path)/a.png")!, base: folder) != nil)
        #expect(MarkdownImage.file(for: URL(string: folder.appendingPathComponent("a.png").path)!, base: nil) != nil)
        #expect(MarkdownImage.file(for: URL(string: "a.png")!, base: folder) != nil)
        // ネットワーク・data・場所の外・ないファイル・フォルダは、出さない
        for bad in ["https://example.com/a.png", "http://example.com/a.png", "data:image/png;base64,AAAA", "file:///etc/hosts", "missing.png", "."] {
            #expect(MarkdownImage.file(for: URL(string: bad)!, base: folder, home: "/nonexistent") == nil, "出さない：\(bad)")
        }
        #expect(MarkdownImage.file(for: URL(string: "file:///etc/hosts")!, base: nil, home: "/nonexistent") == nil)
    }

    @Test func imagesCodexGeneratedAreShownButTheRestOfItsFolderIsNot() throws {
        // Codex の画像生成は、`~/.codex/generated_images/<会話>/<名前>.png` に書く（利用者の報告：会話の画面に出なかった）。認証の情報がある `~/.codex` の全体は、読ませない
        let home = URL(fileURLWithPath: "/private/tmp/vc-home-\(UUID().uuidString)")
        let generated = home.appendingPathComponent(".codex/generated_images/abc")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try writePNG(generated.appendingPathComponent("exec-1.png"))
        let roots = MarkdownImage.roots(base: nil, home: home.path)
        #expect(roots.contains(RealPath.existing(home.path + "/.codex/generated_images") ?? "") && !roots.contains(RealPath.existing(home.path + "/.codex") ?? ""))
    }

    @Test func aLinkOrDotDotThatLeavesTheFolderIsNotFollowed() throws {
        let base = URL(fileURLWithPath: "/private/tmp/vc-mdimg-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("work"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try writePNG(outside.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        // /tmp は、読んでよい場所なので、「作業フォルダの外」を示すには、一時フォルダの外へ出る場所が要る：ホームの代わりに、roots の判定を直接見る
        let roots = MarkdownImage.roots(base: folder, home: "/nonexistent")
        #expect(roots.contains(RealPath.existing(folder.path) ?? ""))
        // リンクは、実際の場所に直す（この例では、/tmp の中なので、読んでよい。実際の場所が、返る）
        let resolved = MarkdownImage.file(for: URL(string: "link.png")!, base: folder, home: "/nonexistent")
        #expect(resolved?.path == RealPath.existing(outside.appendingPathComponent("secret.png").path))
        #expect(MarkdownImage.file(for: URL(string: "../../../../etc/hosts")!, base: folder, home: "/nonexistent") == nil)   // `..` で、場所の外へ
    }

    @Test func aReadableImageInMarkdownBecomesAnAttachmentAndOthersStayLinks() throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        try writePNG(folder.appendingPathComponent("cat.png"))
        func attachments(_ markdown: String) -> Int {
            let rendered = MarkdownRenderer.render(markdown)
            var count = 0
            rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in if value != nil { count += 1 } }
            return count
        }
        #expect(attachments("![猫](file://\(folder.path)/cat.png)") == 1)
        let remote = MarkdownRenderer.render("![猫](https://example.com/cat.png)")
        #expect(remote.string.contains("🖼 猫"))                                                  // ネットワークの画像は、リンクのまま
        #expect(attachments("![猫](https://example.com/cat.png)") == 0)
        #expect(attachments("![猫](file:///etc/hosts)") == 0)                                     // 場所の外は、リンクのまま
        #expect(MarkdownRenderer.plainText("![猫](file://\(folder.path)/cat.png)").contains("猫")) // コピーする文字は、説明
    }

    @Test func anUnreadableOrEmptyFileIsNotShown() throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        try Data("これは画像ではない".utf8).write(to: folder.appendingPathComponent("fake.png"))
        try Data().write(to: folder.appendingPathComponent("empty.png"))
        let fake = try #require(MarkdownImage.file(for: URL(string: "fake.png")!, base: folder))
        #expect(MarkdownImage.image(at: fake) == nil)                                             // 画像として読めない
        #expect(MarkdownImage.file(for: URL(string: "empty.png")!, base: folder) == nil)          // 空
    }
}

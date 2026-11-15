import Foundation
import Testing
@testable import VCSkill

/// Apple のモデルの会話の道具：検索の結果の読み取り・取ってよい URL・作業フォルダの外へ出ない・道具なしでは答えられない依頼の判定。
@Suite struct AppleChatToolsTests {
    @Test func searchResultsAreParsedWithRedirectLinksResolvedAndPrivateTargetsDropped() {
        let html = """
        <div class="result"><a rel="nofollow" class="result__a" href="https://giftee.co.jp/press/news/">ニュース | 株式会社ギフティ</a>
        <a class="result__snippet" href="https://giftee.co.jp/press/news/">プレスリリース&amp;お知らせ</a></div>
        <div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1&amp;rut=abc">中継の記事</a>
        <a class="result__snippet" href="#">中継の説明</a></div>
        <div class="result"><a class="result__a" href="http://192.168.0.1/admin">内部</a><a class="result__snippet" href="#">x</a></div>
        """
        let results = WebText.parseSearch(html)
        #expect(results.map(\.url) == ["https://giftee.co.jp/press/news/", "https://example.com/a?x=1"])
        #expect(results[0].snippet == "プレスリリース&お知らせ" && results[1].title == "中継の記事")
        #expect(WebText.parseSearch("<html>形が変わった</html>").isEmpty)
    }

    @Test func pageTextDropsScriptsAndTagsAndIsClipped() {
        let html = "<html><head><title>t</title></head><body><script>alert(1)</script><style>p{}</style><h1>見出し</h1><p>本文&nbsp;です</p><nav>menu</nav></body></html>"
        let text = WebText.pageText(html)
        #expect(text.contains("見出し") && text.contains("本文 です") && !text.contains("alert") && !text.contains("menu"))
        #expect(WebText.pageText("<p>" + String(repeating: "あ", count: 5000) + "</p>", limit: 100).count <= 101)
    }

    @Test func onlyPublicHttpUrlsMayBeFetched() {
        for ok in ["https://example.com/x", "http://news.yahoo.co.jp/"] { #expect(URLGuard.allows(URL(string: ok)!), "\(ok)") }
        for bad in ["file:///etc/passwd", "ftp://example.com", "http://localhost:8080", "http://127.0.0.1/", "http://10.0.0.5/", "http://192.168.1.1/", "http://172.20.0.1/",
                    "http://169.254.169.254/latest", "http://printer.local/", "http://[::1]/", "https://user:pw@example.com/", "http://2130706433/"] {
            #expect(!URLGuard.allows(URL(string: bad)!), "\(bad)")
        }
    }

    @Test func theFolderReaderNeverLeavesTheWorkingFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vc-folder-\(UUID().uuidString)")
        let root = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "中身".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try "秘密".write(to: base.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: base.appendingPathComponent("secret.txt"))
        defer { try? FileManager.default.removeItem(at: base) }
        let reader = FolderReader(root: root)
        #expect(try reader.read("note.txt") == "中身")
        #expect(try reader.list(".").contains("sub/") && (try reader.list(".")).contains("note.txt"))
        for escape in ["../secret.txt", "/etc/passwd", "~/x", "sub/../../secret.txt", "link.txt"] {
            #expect(throws: FolderReader.Failure.self, "\(escape)") { _ = try reader.read(escape) }   // `link.txt`（外へのシンボリックリンク）も、読めない
        }
        #expect(AppleChatTools.mentionedFile(in: "note.txt には何が書いてある？", folder: root) == "note.txt")
        #expect(AppleChatTools.mentionedFile(in: "secret.txt を読んで", folder: root) == nil)
    }

    @Test func requestsThatNeedAToolAreRecognizedOnlyWhenToolsAreOn() {
        #expect(AppleChatTools.needsTool("ギフティのニュースを調べて", level: .web))
        #expect(AppleChatTools.needsTool("memo.txt を読んで", level: .read))
        #expect(!AppleChatTools.needsTool("memo.txt を読んで", level: .web))        // ファイルの道具は、web にはない
        #expect(!AppleChatTools.needsTool("ギフティのニュースを調べて", level: .none))
        #expect(!AppleChatTools.needsTool("こんにちは", level: .read))
        #expect(AppleChatTools.looksLikeAPromise("まず、一覧にします。") && !AppleChatTools.looksLikeAPromise("青い鳥の話です。"))
    }

    @Test func appleNeverGetsWriteOrCommandTools() {
        #expect(ChatAgent.apple.effective(.all) == .read)
        #expect(AppleChatTools.make(level: .all, folder: URL(fileURLWithPath: "/tmp"), activity: { _ in }).map(\.name).sorted() == ["current_date_time", "fetch_page", "list_files", "read_file", "web_search"])
        #expect(AppleChatTools.make(level: .none, folder: URL(fileURLWithPath: "/tmp"), activity: { _ in }).isEmpty)
    }
}

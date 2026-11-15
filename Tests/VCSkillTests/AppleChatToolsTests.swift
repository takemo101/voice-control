import Foundation
import Testing
import VCDecision
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
        #expect(ToolUseGuard.mentionedFile(in: "note.txt には何が書いてある？", folder: root) == "note.txt")
        #expect(ToolUseGuard.mentionedFile(in: "secret.txt を読んで", folder: root) == nil)
    }

    @Test func requestsThatNeedAToolAreRecognizedOnlyWhenToolsAreOn() {
        #expect(ToolUseGuard.needsTool("ギフティのニュースを調べて", level: .web))
        #expect(ToolUseGuard.needsTool("memo.txt を読んで", level: .read))
        #expect(!ToolUseGuard.needsTool("memo.txt を読んで", level: .web))        // ファイルの道具は、web にはない
        #expect(!ToolUseGuard.needsTool("ギフティのニュースを調べて", level: .none))
        #expect(!ToolUseGuard.needsTool("こんにちは", level: .read))
        #expect(ToolUseGuard.looksLikeAPromise("まず、一覧にします。") && !ToolUseGuard.looksLikeAPromise("青い鳥の話です。"))
    }

    @Test func writeAndCommandToolsExistOnlyAtTheAllLevel() {
        let folder = URL(fileURLWithPath: "/tmp")
        func names(_ level: ChatToolLevel) -> [String] { AppleChatTools.make(level: level, folder: folder, activity: { _ in }).map(\.name).sorted() }
        #expect(names(.all) == ["current_date_time", "fetch_page", "list_files", "read_file", "run_command", "web_search", "write_file"])
        #expect(!names(.read).contains("write_file") && !names(.read).contains("run_command") && !names(.web).contains("read_file"))
        #expect(names(.none).isEmpty)
        #expect(ChatAgent.apple.effective(.all) == .all)
    }

    @Test func commandsAreSortedByTheCodeIntoRunConfirmOrRefuse() {
        let folder = URL(fileURLWithPath: "/tmp/vc-gate-test-folder")
        func decision(_ command: String) -> CommandGate.Decision { CommandGate.classify(command, folder: folder).decision }
        // そのまま実行：読むだけの、よく使うコマンド（フォルダの中）
        for ok in ["ls -la", "pwd", "cat note.txt", "grep -n word notes/a.txt", "head -5 ./a.txt", "date"] { #expect(decision(ok) == .allow, "\(ok)") }
        // 確認：読むだけでも、フォルダの外・~・フラグに含まれるパス／一覧にないコマンド
        for ask in ["cat /etc/hosts", "cat ../secret.txt", "cat ~/.ssh/id_rsa", "ls /", "sort -o/etc/x a.txt", "rm note.txt", "mkdir out", "open -a Safari", "touch a.txt", "git status"] {
            if case .confirm = decision(ask) {} else { Issue.record("確認になるはず: \(ask)") }
        }
        // 実行しない：シェル・インタプリタ・通信・システム・パス指定のコマンド・解釈できない
        for no in ["bash -c ls", "sh script.sh", "sudo ls", "env X=1 ls", "python3 -c 'print(1)'", "node a.js", "osascript -e 'beep'", "curl https://example.com", "ssh host", "/bin/ls", "./run.sh", "cat 'unclosed"] {
            if case .deny = decision(no) {} else { Issue.record("実行しないはず: \(no)") }
        }
        #expect(CommandGate.classify("ls -la", folder: folder).argv == ["ls", "-la"])
    }

    @Test func writesStayInsideTheFolderAndOverwritesAreReportedAsExisting() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vc-write-\(UUID().uuidString)")
        let root = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "外".write(to: base.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: base)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkfile.txt"), withDestinationURL: base.appendingPathComponent("outside.txt"))
        try "既存".write(to: root.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: base) }
        let reader = FolderReader(root: root)
        let new = try reader.resolveForWrite("sub/new.txt")
        #expect(!new.exists)
        try reader.write("こんにちは", to: new.url)
        #expect(try reader.read("sub/new.txt") == "こんにちは")
        #expect(try reader.resolveForWrite("old.txt").exists)   // 上書きは、確認の対象
        for escape in ["../x.txt", "/tmp/x.txt", "~/x.txt", "", "sub/../../x.txt", "linkdir/x.txt", "linkfile.txt"] {
            #expect(throws: FolderReader.Failure.self, "\(escape)") { _ = try reader.resolveForWrite(escape) }   // 外へのリンク経由も、不可
        }
        #expect(try String(contentsOf: base.appendingPathComponent("outside.txt"), encoding: .utf8) == "外")
        #expect(throws: FolderReader.Failure.self) { try reader.write(String(repeating: "あ", count: 200_001), to: new.url) }
        #expect(ToolUseGuard.wantsToChange("memo.txt に確認済みと書いて") && !ToolUseGuard.wantsToChange("memo.txt には何が書いてある？"))
    }

    @Test func attachmentMarksThePanelMimickedAreRemovedAndFileCopiesAreNotClipboardRequests() {
        #expect(ToolUseGuard.cleaned("【添付：】『done.txt』を作成しました。") == "『done.txt』を作成しました。")
        #expect(ToolUseGuard.cleaned("【添付：画像】\n要点です") == "要点です")
        #expect(ChatAttachments.wants("note.txt を note2.txt にコピーして") == .init(image: false, text: false))
        #expect(ChatAttachments.wants("コピーした文章を要約して").text)
    }

    // MARK: 作り話を返さない判断（`ToolUseGuard`。モデルなしで、流れを確かめる）

    private func guardFor(_ user: String, _ level: ChatToolLevel, folder: URL = URL(fileURLWithPath: "/tmp/vc-guard-none")) -> ToolUseGuard { ToolUseGuard(level: level, user: user, folder: folder) }

    @Test func noToolsMeansTheReplyIsAlwaysAccepted() {
        #expect(guardFor("ギフティのニュースを調べて", .none).next(.start, calls: 0, acted: false, reply: "調べます") == .done)
    }

    @Test func aQuestionOnlyTheJudgeCallsFreshIsNudgedOnceButNeverRefused() {
        // 「今日の阪神の試合は？」：言葉の一致では、道具が要る依頼ではない。Tiny-Jev が「最新の情報」と判定した：1 度促す。呼ばれなくても、答えを消さない（誤判定で、正しい答えを失わないため）
        var g = ToolUseGuard(level: .web, user: "今日の阪神の試合は？", folder: URL(fileURLWithPath: "/tmp/vc-guard-none"), judgedWeb: true)
        guard case let .nudge(_, then) = g.next(.start, calls: 0, acted: false, reply: "知っている範囲では…") else { Issue.record("促すはず"); return }
        #expect(g.next(then, calls: 0, acted: false, reply: "分かりません") == .done)           // 促しても呼ばれない：そのまま返す（失敗にしない）
        #expect(g.next(.start, calls: 1, acted: false, reply: "結果です") == .done)             // 呼ばれた：そのまま
        g.judgedWeb = false
        #expect(g.next(.start, calls: 0, acted: false, reply: "知識で答えます") == .done)        // 判定なし：促さない
        #expect(guardFor("ギフティのニュースを調べて", .web).next(.afterNudge, calls: 0, acted: false, reply: "x") != .done)   // 言葉の一致は、これまでどおり、失敗にする
    }

    @Test func theWebNeedJudgeReadsTheFirstOptionAndFailsSafelyToNo() throws {
        struct Fixed: OptionScorer { let p: Double; func score(state: String, question: String, options: [String]) throws -> [Double] { [p] + Array(repeating: (1 - p) / Double(options.count - 1), count: options.count - 1) } }
        struct Broken: OptionScorer { func score(state: String, question: String, options: [String]) throws -> [Double] { throw NSError(domain: "x", code: 1) } }
        #expect(ChatWebNeed(scorer: Fixed(p: ChatWebNeed.threshold)).needsWeb("今日の阪神の試合は？"))
        #expect(!ChatWebNeed(scorer: Fixed(p: 0.59)).needsWeb("日本の首都は？"))
        #expect(!ChatWebNeed(scorer: Broken()).needsWeb("今日の阪神の試合は？"))   // 判定できなければ、「要らない」
    }

    @Test func aSearchRequestWithoutAnyToolCallIsNudgedOnceThenRefused() {
        let g = guardFor("ギフティのニュースを調べて", .web)
        guard case let .nudge(_, then) = g.next(.start, calls: 0, acted: false, reply: "知っている範囲では…") else { Issue.record("促すはず"); return }
        #expect(then == .afterNudge)
        if case .fail = g.next(.afterNudge, calls: 0, acted: false, reply: "やはり知っている範囲では…") {} else { Issue.record("失敗にするはず") }   // 作り話を返さない
        #expect(g.next(.afterNudge, calls: 2, acted: false, reply: "検索の結果です") == .done)                                                 // 呼ばれていれば、よい
        #expect(g.next(.start, calls: 1, acted: false, reply: "検索の結果です") == .done)
    }

    @Test func aPromiseOnlyReplyIsNudgedEvenWhenTheRequestDoesNotNeedATool() {
        let g = guardFor("こんにちは", .web)
        if case .nudge = g.next(.start, calls: 0, acted: false, reply: "確認します。") {} else { Issue.record("予告だけは、促す") }
        #expect(g.next(.start, calls: 0, acted: false, reply: "こんにちは！") == .done)
        #expect(g.next(.afterNudge, calls: 0, acted: false, reply: "どうも") == .done)   // 道具が要る依頼ではないので、呼ばれなくても、失敗にしない
    }

    @Test func aMentionedFileIsReadByTheCodeOnlyForReadRequests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "確認済み".write(to: root.appendingPathComponent("memo.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(guardFor("memo.txt には何が書いてある？", .read, folder: root).next(.afterNudge, calls: 0, acted: false, reply: "作り話") == .readFile(name: "memo.txt", text: "確認済み"))
        if case .fail = guardFor("memo.txt に「上書き」と書いて", .read, folder: root).next(.afterNudge, calls: 0, acted: false, reply: "書きました") {} else { Issue.record("書く依頼は、読んで答えない") }
    }

    @Test func aWriteRequestNeedsAWriteOrCommandCallNotJustAList() {
        let g = guardFor("done.txt というファイルに「確認済み」と書いて作って", .all)
        guard case let .nudge(_, then) = g.next(.afterNudge, calls: 1, acted: false, reply: "作成します") else { Issue.record("促すはず"); return }   // 一覧だけ呼んだ
        #expect(then == .afterActNudge)
        if case .fail = g.next(.afterActNudge, calls: 2, acted: false, reply: "作成します") {} else { Issue.record("した、とは言わせない") }
        #expect(g.next(.afterActNudge, calls: 3, acted: true, reply: "作成しました") == .done)
        #expect(g.next(.afterNudge, calls: 3, acted: true, reply: "作成しました") == .done)                    // 書く道具を呼んだ（確認を断られた場合も）
        #expect(guardFor("done.txt というファイルに書いて", .read).next(.afterNudge, calls: 1, acted: false, reply: "できません") == .done)   // 書く道具は、read にはない
    }

    @Test func webToolsAreLeftOutWhenScreenContentIsInTheConversation() {
        let folder = URL(fileURLWithPath: "/tmp")
        let names = AppleChatTools.make(level: .all, folder: folder, allowsWeb: false, activity: { _ in }).map(\.name).sorted()
        #expect(names == ["current_date_time", "list_files", "read_file", "run_command", "write_file"])   // 検索・ページの取得は、外す。ファイル・コマンドは、この Mac の中だけなので、残す
        let g = ToolUseGuard(level: .web, user: "ギフティのニュースを調べて", folder: folder, allowsWeb: false)
        #expect(g.next(.afterNudge, calls: 0, acted: false, reply: "調べられません") == .done)   // 検索の道具がないのに、「道具を呼ばなかった」と、失敗にしない
    }
}

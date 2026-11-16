import AppKit
import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

/// 会話の「確認」の経路を、**実際のエージェント**で試す（開発用）：声の流れと同じ `ChatVoice.handle`・本物の確認のパネル・本物の会話のウィンドウ。
/// 自作のフォルダに、ファイルを作る依頼をして、確認のパネルが出るのを待ち、ボタンの答え（`AnswerRoute.deliver`）か、Esc（取りやめ）を、送る。画面の中央にウィンドウ、上にパネルが出る。
struct ChatCheckCommand: Command {
    static let info = CommandInfo(
        name: "chat-check", group: .evaluation, summary: "会話の確認パネルの経路を、実際のエージェントで試す（自作のフォルダ・自作の質問。画面にパネルとウィンドウが出る）",
        usage: ["vc chat-check [--agent agy] [--tools none|web|read|all] [--scenario yes,no,esc,hidden,run,ls,outside,blocked,read,web,long,swap] [--folder <フォルダ>]"],
        details: ["道具は、既定で「すべて」。シナリオ：yes＝パネルで許可・no＝パネルで断る・esc＝確認を待つ間に取りやめ（Esc）・hidden＝会話のウィンドウを閉じてから許可・run＝コマンド（echo）の実行を、パネルで許可・ls＝ls（見るだけ：パネルが出ず、通るはず）・blocked＝書き込みを頼む（パネルが出ず、断られる：道具が「すべて」でないとき）・outside＝作業フォルダの外（/tmp）への書き込みを頼み、パネルで許可する（OS の制限〔サンドボックス〕で、書けないはず）・read＝フォルダのファイルを読ませる・web＝Web 検索をさせる・long＝長い会話（11 問。合言葉を覚えているか・1 問ごとの時間・子プロセスの数）・swap＝会話の途中で設定（道具の段階）を変えて、古い子プロセスが止まるか。シナリオごとに、作ったファイルの有無を出す。同じエージェントの接続で、続けて試す。"],
        options: [("--agent <名前>", "既定 agy"), ("--tools <段階>", "会話の道具の段階（既定 all）"), ("--scenario <名前,…>", "既定 yes,no,esc,hidden"), ("--folder <フォルダ>", "作業フォルダ（既定：一時のフォルダ）")],
        examples: ["vc chat-check", "vc chat-check --scenario yes"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        guard let agent = ChatAgent.parse(arguments.option("--agent") ?? "agy"), agent.isExternal else { usageError("chat-check", "--agent は、外のエージェントを指定してください") }
        let level = ChatToolLevel(rawValue: arguments.option("--tools") ?? "all") ?? .all
        let scenarios = (arguments.option("--scenario") ?? "yes,no,esc,hidden").split(separator: ",").map(String.init)
        let folder = arguments.option("--folder").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("vc-chat-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let jev = context.loadJev()
        ChatMode.shared.scorer = jev
        ChatMode.shared.configure(agent: agent, tools: level, folder: folder)
        setvbuf(stdout, nil, _IOLBF, 0)   // 行ごとに出す（撮影のスクリプトが、PANEL の行を、すぐ見られるように）
        NSApplication.shared.setActivationPolicy(.accessory)
        HUD.shared.warmUp()
        let check = ChatCheckRun(agent: agent, level: level, folder: folder, context: context, confirmation: Confirmation(scorer: jev))
        Task { @MainActor in
            print("作業フォルダ：\(folder.path)")
            for name in scenarios {
                switch name {
                case "long": await check.long()
                case "swap": await check.swap()
                case "blocked", "read", "web", "ls": await check.withoutPanel(name)
                default: await check.withPanel(name)
                }
            }
            print("\n終わり")
            exit(0)
        }
        NSApplication.shared.run()
    }
}

/// 1 回の実行（シナリオごとの流れ）。画面（パネル・ウィンドウ）を使うので、主スレッド。
@MainActor private final class ChatCheckRun {
    let agent: ChatAgent
    let level: ChatToolLevel
    let folder: URL
    let context: CommandContext
    let confirmation: Confirmation
    /// 声の「はい」を、待たない（パネルのボタンだけで答える）。
    private let waitForever: NextUtterance = { try await Task.sleep(for: .seconds(86_400)); return nil }

    init(agent: ChatAgent, level: ChatToolLevel, folder: URL, context: CommandContext, confirmation: Confirmation) {
        self.agent = agent; self.level = level; self.folder = folder; self.context = context; self.confirmation = confirmation
    }

    // MARK: 共通

    /// この Mac で、いま動いている、そのエージェントの ACP の子プロセスの数（`<名前> acp`）。
    private func children() -> Int {
        let result = ProcessRunner.run(executable: "pgrep", arguments: ["-f", "\(agent.rawValue) acp"], mergeStderr: false, timeout: 5)
        guard result.launchError == nil else { return -1 }
        return String(decoding: result.output, as: UTF8.self).split(separator: "\n").count
    }

    /// 1 回の質問（声の流れと同じ `ChatVoice.handle`）。かかった秒数。
    private func ask(_ question: String) async -> Double {
        let started = Date()
        await ChatVoice.handle(question, token: CancelToken(), context: context, chip: "確認", speakResults: false, confirmation: confirmation, next: waitForever, cancelHook: nil)
        return Date().timeIntervalSince(started)
    }

    /// 質問を、別のタスクで始める（取りやめ・パネルの待ちを、こちらで操作するため）。
    private func start(_ question: String, token: CancelToken) -> Task<Void, Never> {
        Task { @MainActor in
            await ChatVoice.handle(question, token: token, context: context, chip: "確認", speakResults: false, confirmation: confirmation, next: waitForever, cancelHook: nil)
        }
    }

    /// 終わるまで待つ（上限つき）。終わったか。
    private func finished(_ task: Task<Void, Never>, within seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func seconds(since date: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(date)) }

    private func fileMade(_ file: URL) -> String { FileManager.default.fileExists(atPath: file.path) ? "はい" : "いいえ" }

    private func question(for name: String) -> String {
        switch name {
        case "run": return "echo hello をシェルで実行して、結果を教えて"
        case "ls": return "ls コマンドで、この作業フォルダの一覧を取って、結果を教えて"
        case "outside": return "/tmp/vc-chat-check-outside.txt というファイルを作って、中身は hi にして"
        case "read": return "a.txt の中身を読んで、foo を含む行を教えて"
        case "web": return "Web で『Swift 6.2 リリース』を検索して、1 行で教えて"
        default: return "check-\(name).txt というファイルを作って、中身は hi にして"
        }
    }

    /// 作る（作らせない）ファイル。毎回、消してから始める。読ませるファイル（`a.txt`）も、置く。
    private func prepare(_ name: String) -> URL {
        let file = name == "outside" ? URL(fileURLWithPath: "/tmp/vc-chat-check-outside.txt") : folder.appendingPathComponent("check-\(name).txt")
        try? FileManager.default.removeItem(at: file)   // try?: なくてもよい
        try? "hello world\nfoo bar\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)   // try?: 開発用。書けなければ、読むシナリオが、そう答える
        return file
    }

    // MARK: 長い会話・設定の変更

    /// 長い会話（11 問）：合言葉を覚えているか・1 問ごとの時間・子プロセスの数。
    func long() async {
        print("\n■ シナリオ long")
        let filler = String(repeating: "これは長さを稼ぐための文章です。", count: 90)
        let questions = ["合言葉は『みかん42』です。覚えて、『覚えた』とだけ答えて。"] + (1...9).map { "質問\($0)：次の文は読み流して、『了解\($0)』とだけ答えて。\(filler)" } + ["最初に教えた合言葉は？"]
        for (index, question) in questions.enumerated() {
            let took = await ask(question)
            print("  [\(index + 1)/\(questions.count)] \(String(format: "%.1f", took)) 秒・\(agent.rawValue) の ACP の子プロセス：\(children())")
        }
    }

    /// 会話の途中で、設定（道具の段階）を変えて、古い子プロセスが止まるか。
    func swap() async {
        print("\n■ シナリオ swap")
        _ = await ask("合言葉は『りんご7』です。覚えて、『覚えた』とだけ答えて。")
        print("  段階 \(level.rawValue)：子プロセス \(children())")
        let other: ChatToolLevel = level == .read ? .web : .read
        ChatMode.shared.configure(agent: agent, tools: other, folder: folder)   // 設定を変えた（会話は、新しくなる）
        try? await Task.sleep(for: .seconds(1))
        print("  設定を変えた直後（段階 \(other.rawValue)）：子プロセス \(children())（古いものが止まって、新しい質問の前は 0 のはず）")
        _ = await ask("合言葉は？（覚えていなければ、そう答えて）")
        print("  次の質問のあと：子プロセス \(children())（1 のはず）")
    }

    // MARK: 確認のパネル

    /// パネルが出ないはずのシナリオ（断られる・読む・Web・`ls`）：終わるまで、パネルが出ないことを見る。
    func withoutPanel(_ name: String) async {
        let file = prepare(name)
        let started = Date()
        print("\n■ シナリオ \(name)")
        let task = start(question(for: name), token: CancelToken())
        let watch = PanelWatch()
        let watcher = Task { @MainActor in while !Task.isCancelled { watch.poll(); try? await Task.sleep(for: .milliseconds(100)) } }
        await task.value
        watcher.cancel()
        print("結果：処理は終わった・確認のパネル：\(watch.seen ? "出た" : "出なかった")・ファイルを作った：\(fileMade(file))・待ち時間 \(seconds(since: started)) 秒")
    }

    /// パネルが出るシナリオ：出るまで待ち、答える（許可・断る・Esc・ウィンドウを閉じてから許可）。
    func withPanel(_ name: String) async {
        let file = prepare(name)
        let token = CancelToken()
        let started = Date()
        print("\n■ シナリオ \(name)")
        let task = start(question(for: name), token: token)
        var waited = 0.0
        while !HUD.shared.answers.isWaiting, waited < 120 { try? await Task.sleep(for: .milliseconds(200)); waited += 0.2 }
        guard HUD.shared.answers.isWaiting else { print("PANEL なし（\(Int(waited)) 秒待ったが、確認のパネルが出なかった）"); task.cancel(); return }
        print("PANEL 確認のパネルが出た（\(seconds(since: started)) 秒）")
        try? await Task.sleep(for: .milliseconds(2500))   // 画面を撮れるように、少し見せる
        switch name {
        case "yes", "run", "outside": HUD.shared.answers.deliver(true); print("→ パネルで、許可")
        case "no": HUD.shared.answers.deliver(false); print("→ パネルで、断る")
        case "esc": token.cancel(); task.cancel(); print("→ 確認を待つ間に、取りやめ（Esc）")
        case "hidden":
            ChatWindow.shared.hide(); print("→ 会話のウィンドウを閉じた")
            try? await Task.sleep(for: .milliseconds(500))
            HUD.shared.answers.deliver(true); print("→ パネルで、許可")
        default: print("知らないシナリオ"); task.cancel()
        }
        let done = await finished(task, within: 90)
        print("結果：\(done ? "処理は終わった" : "90 秒たっても終わらない")・ファイルを作った：\(fileMade(file))・パネルの待ち：\(HUD.shared.answers.isWaiting ? "残っている" : "解けた")・待ち時間 \(seconds(since: started)) 秒")
        try? await Task.sleep(for: .milliseconds(1500))
    }
}

/// 確認のパネルが、一度でも出たか（質問の間、見張る）。
@MainActor private final class PanelWatch {
    private(set) var seen = false
    func poll() { if HUD.shared.answers.isWaiting { seen = true } }
}

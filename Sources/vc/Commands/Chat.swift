import Foundation
import VCCore
import VCSkill

struct ChatCommand: Command {
    static let info = CommandInfo(
        name: "chat", group: .evaluation, summary: "会話の試験用の REPL（実機のモデルで、会話・要約を試す。声で使うのは、アプリの会話のキー）",
        usage: ["vc chat [--agent <名前>] [--stats] [--delimit]"],
        details: [
            "**スキルを選ばずに、会話として質問できる**（Apple のオンデバイスのモデル。この Mac の外へ出さない）。標準入力から、1 行ずつ質問を読み、答えを出す（空行・Ctrl+D で終わる）。声で使うには、アプリの設定ウィンドウ > キー で、会話のキーを決める。",
            "**会話の記録は、メモリだけ**（ファイル・ログに残さない）。終わると、消える。「会話を終わって」「新しい会話」（vc chat では /reset）・5 分間話さない・vc を終える、で消える。",
            "**compaction**：会話が長くなる（モデルの文脈は 8,192 トークン）前に、古いやり取りを、要約に置き換えて、続ける。前の要約を渡して、更新させる（利用者が言った前提・数値・名前・日時を、残す）。要約が失敗しても、会話は止まらない。",
            "**画像・文章を添えられる**：「この画像は何？」「この画面の右上の数字は？」（撮ったスクリーンショットか、コピーした画像）・「コピーした文章を要約して」（コピーした文章）。添えるかは、言葉で、コードが決める。画像は、1 度だけ、文字（説明と、画像の中の文字）にして、会話に入れる。同じ画像は、2 度、入れない。",
            "**会話では、スキルを実行しない**（Spotify を操作する・ファイルを開く、などは、アプリの声で頼むキーで）。調べものは、ask-agent。小さなモデル（約 3B）なので、事実の質問は、間違える。整理・要約・言い換え・手元の画像や文章についての質問が、得意。",
            "--stats：終わるときに、往復の数・要約の回数・要約の長さを、標準エラーに出す。入力の /reset：会話を終える・/summary：いまの要約を見る（確認用）。",
        ],
        options: [("--agent <名前>", "このときだけ、会話に使うエージェント（既定は、設定ウィンドウ > モデル）"), ("--tools <段階>", "外のエージェントに開ける道具：none・web・read・all（既定は、設定）"), ("--folder <フォルダ>", "道具を開けたときの作業フォルダ"), ("--stats", "終わるときに、往復の数・要約の回数・要約の長さを出す"), ("--delimit", "答えの終わりに、区切り（RS：0x1e）の行を出す（スクリプトで、答えを分けるため）")],
        examples: ["vc chat", "echo '私の好きな色は青です' | vc chat"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let stats = arguments.flag("--stats")
        let delimit = arguments.flag("--delimit")
        var agent = context.resolveChatAgent()
        if let name = arguments.option("--agent") {
            guard let chosen = ChatAgent.parse(name) else { fail("--agent「\(name)」は、使えません（\(ChatAgent.allCases.map(\.rawValue).joined(separator: "・"))）") }
            agent = chosen
        }
        var chatTools = context.resolveChatTools()
        if let name = arguments.option("--tools") {
            guard let level = ChatToolLevel(rawValue: name) else { fail("--tools「\(name)」は、使えません（\(ChatToolLevel.allCases.map(\.rawValue).joined(separator: "・"))）") }
            chatTools.level = level
        }
        if let folder = arguments.option("--folder") { chatTools.folder = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath) }
        ChatMode.shared.configure(agent: agent, tools: chatTools.level, folder: chatTools.folder)
        if !agent.isExternal, ChatMode.shared.tools != .none { notice("Apple のモデル＋道具（\(ChatMode.shared.tools.title)）— 検索語と、開いたページの URL が、この Mac の外へ送られます") }
        if agent.isExternal { notice("エージェント：\(agent.label) — 発話が、この Mac の外へ送られます" + (ChatMode.shared.tools == .none ? "" : "（道具：\(ChatMode.shared.tools.title)）")) }
        let interactive = isatty(STDIN_FILENO) != 0
        if interactive { notice("会話（空行・Ctrl+D で終わる。/reset・/summary）") }
        let chat = ChatMode.shared
        while true {
            if interactive { print(Style.bold("> "), terminator: ""); fflush(stdout) }
            guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "/reset" { await chat.end(); print(Style.dim("（会話を終えました）")); continue }
            if text == "/summary" { print(await chat.conversation.currentSummary ?? Style.dim("（要約は、まだありません）")); continue }
            do {
                // 確認が要る操作（上書き・安全でないコマンド）は、端末で聞く（端末でなければ、確認できないので、その操作は、しない）
                let confirm: ToolConfirm? = interactive ? { @Sendable detail in
                    eprint(Style.yellow("確認：\(detail)。実行しますか？ [y/N] "))
                    return (readLine() ?? "").lowercased().hasPrefix("y")
                } : nil
                let outcome = try await chat.ask(text, engine: context.engine, token: nil, progress: { if interactive { eprint(Style.dim($0)) } }, confirm: confirm)
                for note in outcome.notes { eprint(Style.dim(note)) }
                for activity in outcome.activities { eprint(Style.dim("▸ " + activity)) }
                print(outcome.answer)
                if delimit { print("\u{1e}"); fflush(stdout) }
            } catch { eprint(Style.red("失敗: ") + "\(error)"); if delimit { print("\u{1e}"); fflush(stdout) } }
        }
        if stats {
            let s = await chat.conversation.stats
            eprint("往復 \(s.turns)・要約 \(s.compactions) 回（失敗 \(s.failures)）・いまの要約 \(s.summaryCharacters) 文字")
        }
    }
}

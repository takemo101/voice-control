import Foundation
import VCCore
import VCSkill

struct ChatAgentCommand: Command {
    static let info = CommandInfo(
        name: "chat-agent", group: .settings, summary: "会話（vc chat・会話のキー）に使うエージェントを選ぶ（実験）",
        usage: ["vc chat-agent [show]", "vc chat-agent set <エージェント>", "vc chat-agent reset"],
        details: [
            "設定は ~/.voice-control/settings.json の chatAgent。**既定は apple（この Mac の Apple のモデル。外へ出さない）**。",
            "選べるもの：apple・agy（Antigravity。Google）・claude（Claude Code。Anthropic）・codex（OpenAI）・grok（xAI）・opencode・pi。agy 以降は、コーディングエージェントの CLI を、**会話の答えを作るためだけに**使う（毎回 1 回だけの実行。空の作業フォルダ・読むだけ・Web なし。会話の続きは、vc が、過去の往復を渡して作る）。",
            "**apple 以外を選ぶと、会話の発話（と、要約のための過去の往復）が、そのエージェントの提供元へ送られる**（vc の「この Mac の外へ出さない」の例外。ask-agent と同じ：選んだ人だけ）。画像・コピーした文章は、外へは渡さない（Apple のときだけ）。会話の表示に、使っているエージェントを出す。",
            "使う CLI を、この Mac に入れて、一度起動してログインしておく。入っていなければ、会話は失敗する（Apple へ、黙って切り替えない）。agy のモデルは、環境変数 ASK_AGENT_AGY_MODEL（ask-agent と同じ）。claude・codex・pi は、履歴を残さないオプションを付ける。agy・grok・opencode は、CLI 側の履歴に残りうる。",
            "エージェントを替えると、いまの会話は、新しくなる。次の vc listen --hotkey・vc chat から有効。",
        ],
        options: [],
        examples: ["vc chat-agent", "vc chat-agent set agy", "vc chat-agent reset"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let sub = arguments.positionals.first ?? "show"
        var settings = context.currentSettings()
        switch sub {
        case "show":
            heading("会話のエージェント")
            let agent = context.resolveChatAgent()
            kv("いまの設定", Style.bold(agent.rawValue) + Style.dim("（\(agent.label)）" + (settings.chatAgent == nil ? "（既定）" : "")))
            if agent.isExternal { kv("送り先", Style.yellow("会話の発話が、この Mac の外（提供元）へ送られます")) }
            let installed = ChatAgent.allCases.filter(\.isExternal).map { a in
                a.rawValue + (ProcessRunner.run(executable: a.rawValue, arguments: ["--version"], mergeStderr: false, timeout: 10).exitCode == 127 ? "（なし）" : "")
            }
            kv("この Mac に", installed.joined(separator: "・"))
            print("")
            notice("変える：vc chat-agent set <エージェント>。既定（apple）に戻す：vc chat-agent reset")
        case "set":
            guard arguments.positionals.count >= 2 else { usageError("chat-agent", "エージェントを渡してください（\(ChatAgent.allCases.map(\.rawValue).joined(separator: "・"))）") }
            let text = arguments.positionals[1]
            guard let agent = ChatAgent.parse(text) else { fail("「\(text)」は、使えません（\(ChatAgent.allCases.map(\.rawValue).joined(separator: "・"))）") }
            settings.chatAgent = agent == .apple ? nil : agent.rawValue
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            heading("会話のエージェント")
            kv("設定した", Style.bold(agent.rawValue) + Style.dim("（\(agent.label)）"))
            if agent.isExternal { notice("会話の発話が、\(agent.label) の提供元へ送られます（画像・コピーした文章は、渡しません）") }
            notice("次の vc listen --hotkey・vc chat から有効")
        case "reset":
            settings.chatAgent = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（apple）に戻しました")
        default:
            usageError("chat-agent", "知らないサブコマンド: \(sub)（show・set・reset）")
        }
    }
}

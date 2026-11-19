import Foundation
import VCCore
import VCSkill

struct ChatModelsCommand: Command {
    static let info = CommandInfo(
        name: "chat-models", group: .evaluation, summary: tr("会話のエージェントが選べるモデルの一覧を、取る（ACP。質問は送らない）"),
        usage: [tr("vc chat-models [<エージェント>] [<絞り込みの語>] [--no-sandbox]")],
        details: [
            tr("エージェント（agy・opencode・claude・codex。ACP で話せるもの。既定：設定の会話のエージェント）を、一時的に起動して、初期化とセッションの作成だけを行い、返ってきた、モデルの一覧と、いまのモデルを出す。**質問は送らないので、モデルは呼ばれない**（契約の利用枠は、使わない）。"),
            tr("絞り込みの語（あいまい検索：順に含まれていればよい。空白で区切った語は、すべて含むもの。例：`son 5`）を渡すと、合うものだけを、よく合う順に出す。一覧は、エージェント自身が返す（こちらは、モデルの名前を持たない）。選んだモデルは、設定 `chatModels`（設定ウィンドウ > 会話）か、`vc chat --model <値>`。"),
        ],
        options: [("--no-sandbox", tr("OS の制限なしで起動する"))],
        examples: ["vc chat-models claude", "vc chat-models opencode haiku", "vc chat --agent codex --agent-model gpt-6.1-sol[high]"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let sandbox = !arguments.flag("--no-sandbox") && (context.currentSettings().chatSandbox ?? true)
        let agent: ChatAgent
        let query = arguments.positionals.dropFirst().joined(separator: " ")
        if let name = arguments.positionals.first {
            guard let parsed = ChatAgent.parse(name) else { usageError("chat-models", tr("エージェント「\(name)」を、知りません")) }
            agent = parsed
        } else {
            agent = context.resolveChatAgent()
        }
        guard agent.speaksACP else { fail(tr("\(agent.rawValue) は、ACP で話せないので、一覧を取れません（agy・opencode・claude・codex）")) }
        do {
            let listing = try await ACPModelCatalog.list(for: agent, sandbox: sandbox)
            let chosen = context.currentSettings().chatModels?[agent.rawValue]
            let shown = FuzzyMatch.filter(listing.choices, query: query) { "\($0.id) \($0.name)" }
            print(query.isEmpty ? tr("\(agent.rawValue) のモデル（\(listing.choices.count) 件）：") : tr("\(agent.rawValue) のモデル（「\(query)」に合う \(shown.count) 件／全 \(listing.choices.count) 件）："))
            for choice in shown {
                let marks = (choice.id == listing.current ? tr(" ← エージェントの設定") : "") + (choice.id == chosen ? tr(" ← 選んでいる") : "")
                print("  \(choice.id)" + (choice.name != choice.id ? tr("（\(choice.name)）") : "") + marks)
            }
        } catch { fail("\(error)") }
    }
}

import Foundation
import VCPCControl

struct LLMCommand: Command {
    static let info = CommandInfo(
        name: "llm", group: .evaluation, summary: "Apple の言語モデルが選ぶ次の 1 手を見る",
        usage: ["vc llm <snapshot.json> <発話>"],
        details: ["環境変数 VC_LLM_DEBUG=1 で、モデルの生の出力も表示する。"],
        options: [], examples: ["vc llm corpus/snapshots/fixture-en.json \"削除して\""])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc llm <snapshot.json> <発話>：言語モデルが選ぶ次の 1 手を見る（VC_LLM_DEBUG=1 で、生の出力も）。
        let positionals = arguments.positionals
        // try?: 読めなければ、同じ行の else で usage を出して終了する
        guard positionals.count >= 2, let data = try? Data(contentsOf: URL(fileURLWithPath: positionals[0])), let snap = try? SnapshotParser.parse(data) else { fail("usage: vc llm <snapshot.json> <発話>") }
        // try?: apps.txt（アプリ名の一覧）は、なくてもよい（空の一覧で続ける）
        let apps = ((try? String(contentsOfFile: "corpus/apps.txt", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        do { print(try await LLMPlanner(desktop: ReplayDesktop(snapshot: snap, apps: apps)).next(utterance: positionals[1], done: [])) } catch { fail("\(error)") }
    }
}

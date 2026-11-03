import Foundation
import VCPCControl

struct DecomposeCommand: Command {
    static let info = CommandInfo(
        name: "decompose", group: .evaluation, summary: "長い依頼の分け方を、ルールと言語モデルで比べる",
        usage: ["vc decompose <発話>"], details: [], options: [], examples: ["vc decompose \"Chromeを開いて最近の流行を検索して\""])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc decompose <発話>：長い依頼の分け方を、ルール（ClauseSplitter）と言語モデル（FoundationModels）で比べる。
        guard let utterance = arguments.positionals.first else { usageError("decompose", "発話を渡してください") }
        heading("ルール")
        for (i, c) in ClauseSplitter.split(utterance).enumerated() { print("  \(i + 1). \(c)") }
        do {
            let t0 = Date()
            let steps = try await LLMDecomposer().steps(for: utterance)
            heading("言語モデル" + Style.dim("（\(seconds(t0))）"))
            for (i, c) in steps.enumerated() { print("  \(i + 1). \(c)") }
        } catch { fail("\(error)") }
    }
}

import FoundationModels
import Foundation

/// 長い依頼を、1 手ずつの短い命令文に、書き直す（Apple の FoundationModels。オンデバイス）。
/// 選ぶ・実行を決めるのは、ここではない：書き直した各文は、`Planner`（Tiny-Jev）とゲートが、1 文ずつ判断する。
/// 検証：かぎ括弧の中の文字は、元の依頼にあるものだけ（言語モデルが、入力する文字を作らないように）。
public struct LLMDecomposer: Sendable {
    public enum Failure: Error { case unavailable(String) }

    public init() throws {
        if case .unavailable(let reason) = SystemLanguageModel.default.availability { throw Failure.unavailable("\(reason)") }
    }

    private static let schema: GenerationSchema = {
        let root = DynamicGenerationSchema(name: "Steps", description: "依頼を、1 手ずつに分けたもの", properties: [
            .init(name: "steps", description: "1 手ずつの短い命令文（「〜して」の形）。依頼の順。",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 1, maximumElements: 8)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }()

    private static let instructions = """
    あなたは、パソコンを声で操作する依頼を、1 手ずつの短い命令文に分ける係です。
    - 1 つの命令文には、操作を 1 つだけ入れる（アプリを開く・ボタンを押す・文字を入力する・キーを押す・スクロール・ウィンドウの操作・検索）。
    - 音声認識の聞き違い・言い間違いは、文脈から直す。
    - 入力・検索する文字は、依頼にある文字をそのまま、かぎ括弧「」で囲む。文字を作らない。
    - 依頼にない手を、足さない。「〜を表示して」のような、結果の説明だけの文は、手にしない。
    例：依頼「まずメモをアクティブにして、それから新しいノートを作るボタンを押してください」
      → ["メモをアクティブにして", "新しいノートを作るボタンを押して"]
    """

    public func steps(for utterance: String) async throws -> [String] {
        let session = LanguageModelSession(instructions: Self.instructions)
        let content = try await session.respond(to: "依頼: \(utterance)", schema: Self.schema).content
        let steps = try content.value([String].self, forProperty: "steps").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return steps.filter { Self.quotedTextsAreFromRequest($0, request: utterance) }
    }

    /// かぎ括弧の中の文字が、すべて、元の依頼にあること（空白の違いは無視）。
    static func quotedTextsAreFromRequest(_ step: String, request: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: "[「『]([^」』]+)[」』]")
        let squash: (String) -> String = { $0.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "").lowercased() }
        let r = squash(request)
        return regex.matches(in: step, range: NSRange(step.startIndex..., in: step)).allSatisfy { m in
            guard let range = Range(m.range(at: 1), in: step) else { return false }
            return r.contains(squash(String(step[range])))
        }
    }
}

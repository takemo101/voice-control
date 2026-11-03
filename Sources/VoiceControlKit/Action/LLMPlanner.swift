import FoundationModels
import Foundation

/// Apple の FoundationModels（オンデバイスの言語モデル）で、「次の 1 手」を決める。
/// 出力の形は、動的なスキーマで固定する（`@Generable` のマクロは、Command Line Tools だけの環境では、プラグインが無く使えない）。
/// 言語モデルは、コマンドの文字列を作らない：候補の番号・アプリ名・入力する文字だけを返し、**検証してから** `Step` にする。
public struct LLMPlanner: Sendable {
    public enum Next: Sendable, Equatable {
        case step(Step)
        /// 依頼は、すべて済んだ。
        case finished
        /// 操作の依頼ではない。
        case notACommand
        /// 出力が、検証に通らなかった（理由は、ログに残さない内容だけ）。
        case invalid(String)
    }

    public enum Failure: Error { case unavailable(String) }

    private let desktop: Desktop

    public init(desktop: Desktop) throws {
        self.desktop = desktop
        if case .unavailable(let reason) = SystemLanguageModel.default.availability { throw Failure.unavailable("\(reason)") }
    }

    private static let kinds = ["operate", "openApp", "typeText", "search", "finished", "notACommand"]
    private static let schema: GenerationSchema = {
        let kind = DynamicGenerationSchema(name: "Kind", description: "次の 1 手の種類", anyOf: kinds)
        let step = DynamicGenerationSchema(name: "NextStep", description: "次の 1 手", properties: [
            .init(name: "kind", description: "種類。operate=候補の番号の操作、openApp=アプリを開く、typeText=文字を入力、search=検索、finished=依頼は全部済んだ、notACommand=操作の依頼ではない", schema: DynamicGenerationSchema(referenceTo: "Kind")),
            .init(name: "target", description: "operate のときだけ：候補の文を、番号を除いて、そのまま写す", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "text", description: "openApp のときはアプリ名（開けるアプリから）。typeText・search のときは、依頼の中の文字そのまま", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
        ])
        return try! GenerationSchema(root: step, dependencies: [kind])
    }()

    private static let instructions = """
    あなたは、パソコンを声で操作する依頼の、計画係です。依頼のうち、まだ実行されていない最初の 1 手だけを決めます。
    - 候補にある操作は、kind=operate と、target に候補の文を、番号を除いてそのまま写す。
    - アプリを開く・前面に出す（アクティブにする）のは、kind=openApp と、text に開けるアプリの名前。
    - 文字を入力するのは kind=typeText、検索は kind=search。text は、依頼にある文字をそのまま（作らない）。
    - 依頼の最後まで済んだら kind=finished。操作の依頼ではない発話（会話・独り言）は kind=notACommand。
    - 依頼にない操作は、選ばない。同じ操作を、実行済みなのに繰り返さない。
    例（候補：「1. ボタンを押す: OK」「2. キー操作: 保存」）
    - 依頼「OKを押して」→ kind=operate, target=「ボタンを押す: OK」
    - 依頼「「おはよう」と入力して」→ kind=typeText, text=おはよう
    - 依頼「地図を開いて」→ kind=openApp, text=地図
    - 依頼「今日は暑いね」→ kind=notACommand
    """

    /// 「3. ボタンを押す: OK」のように、番号が付いていても、番号を外す。
    static func stripNumber(_ s: String) -> String {
        s.replacingOccurrences(of: "^[0-9]+[.．、)）]\\s*", with: "", options: .regularExpression)
    }

    /// 次の 1 手。`done`：実行済みの手の、短い説明（前から順）。
    public func next(utterance: String, done: [String]) async throws -> Next {
        let snapshot = try desktop.snapshot()
        let elements = snapshot.elements.filter { $0.canClick && !$0.name.isEmpty }.prefix(80)
        var candidates: [(label: String, step: Step)] = []
        for e in elements { candidates.append(("\(Planner.roleLabel(e.role))を押す: \(e.name.prefix(30))", .click(e))) }
        for s in Shortcut.all { candidates.append(("キー操作: \(s.option)", .press(s))) }
        if let target = snapshot.elements.first(where: \.isScrollable) {
            for d in ScrollDirection.allCases { candidates.append((d.option, .scroll(d, target))) }
        }
        if !snapshot.app.isEmpty { for a in WindowAction.allCases { candidates.append((a.option, .window(a, app: snapshot.app))) } }
        let apps = try desktop.apps()

        let list = candidates.enumerated().map { "\($0.offset + 1). \($0.element.label)" }.joined(separator: "\n")
        let prompt = """
        依頼: \(utterance)
        実行済み: \(done.isEmpty ? "なし" : done.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " / "))
        いまの前面アプリ: \(snapshot.app.isEmpty ? "不明" : snapshot.app)
        開けるアプリ: \(apps.prefix(120).joined(separator: "、"))
        候補:
        \(list)
        """
        let session = LanguageModelSession(instructions: Self.instructions)
        let content = try await session.respond(to: prompt, schema: Self.schema).content
        if ProcessInfo.processInfo.environment["VC_LLM_DEBUG"] != nil { print("LLM raw: \(content.jsonString)") }   // 検証用
        let kind = try content.value(String.self, forProperty: "kind")
        let target = ((try? content.value(String?.self, forProperty: "target")) ?? nil)?.trimmingCharacters(in: .whitespaces)
        let text = ((try? content.value(String?.self, forProperty: "text")) ?? nil)?.trimmingCharacters(in: .whitespaces)

        switch kind {
        case "finished": return .finished
        case "notACommand": return .notACommand
        case "operate":
            guard let target, let hit = candidates.first(where: { $0.label == Self.stripNumber(target) }) else { return .invalid("候補にない文") }
            return .step(hit.step)
        case "openApp":
            guard let text, let name = apps.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else { return .invalid("開けるアプリにない名前") }
            return .step(.openApp(name))
        case "typeText", "search":
            // 入れる文字は、依頼の中にある文字だけ（言語モデルが、文字を作らないように）。
            guard let text, !text.isEmpty, utterance.localizedCaseInsensitiveContains(text) else { return .invalid("入力する文字が、依頼の中にない") }
            if kind == "search" {
                guard !snapshot.app.isEmpty else { return .invalid("前面のアプリが不明") }
                return .step(.search(text, app: snapshot.app))
            }
            let fields = snapshot.elements.filter(\.isTextInput)
            guard let field = fields.first(where: \.isFocused) ?? fields.first else { return .invalid("文字を入れる欄がない") }
            return .step(.type(text: text, into: field))
        default: return .invalid("知らない種類")
        }
    }
}

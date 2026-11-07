import Foundation

/// 1 つの依頼を、順に実行するステップに分けた結果（`vc run`・声の流れ）。**分け方を決めるのは、言語モデル**（`LLMPlanner`）。
/// コードは、モデルの出力を**検査するだけ**（`PlanValidator`）：型付きの値（文の並び）だけを受け取り、疑わしければ、分けない（`.single`）。
public enum RequestPlan: Sendable, Equatable {
    /// 分けない（1 つの依頼。いまの動きと同じ）。
    case single
    /// 順に実行するステップ（2〜`PlanValidator.maxSteps` 個。依頼の文から切り出した短い文）。
    case steps([String])
}

/// 分け方を、受け取らなかった理由（検査で、分けないことにした）。表示・測定のため。
public enum PlanRejection: Sendable, Equatable {
    /// 配列として読めない。
    case unreadable
    /// ステップが多すぎる。
    case tooMany(Int)
    /// 空・長すぎる・重複するステップがある。
    case invalidStep
    /// 依頼にない内容を足している（言い換えを超えて）。
    case ungrounded
}

public struct PlanDecision: Sendable, Equatable {
    public let plan: RequestPlan
    /// 受け取らなかった理由（分けなかっただけで、拒否でないなら nil）。
    public let rejection: PlanRejection?
}

/// 言語モデルの出力（JSON の文字列の配列）の検査。**外から来る値（言語モデルの出力）を、ここで 1 回だけ、型にする。**
/// - 配列が 0 個・1 個：分けない。
/// - `maxSteps` を超える・空・長すぎる・重複する：分けない。
/// - **依頼にない内容を足したステップ**（「次の曲にして」→「曲を選んで」「曲を再生して」）は、分けない：ステップの文字の組（2 文字ずつ）の 6 割以上が、依頼にあること（言い換え・活用の違いは、許す）。
/// 検査を通らなければ、分けない（いまの 1 依頼 = 1 スキルの動き）。分けても、許可の照合・確認は、ステップごとに、これまでの経路で行う（権限は、広がらない）。
public enum PlanValidator {
    public static let maxSteps = 3
    static let maxStepLength = 200
    static let minGrounding = 0.6

    public static func validate(output: String, request: String) -> PlanDecision {
        guard let steps = parse(output) else { return PlanDecision(plan: .single, rejection: .unreadable) }
        if steps.count <= 1 { return PlanDecision(plan: .single, rejection: nil) }
        if steps.count > maxSteps { return PlanDecision(plan: .single, rejection: .tooMany(steps.count)) }
        var seen = Set<String>()
        for step in steps {
            guard !step.isEmpty, step.count <= maxStepLength, seen.insert(key(step)).inserted, normalized(step).count >= 2 else {
                return PlanDecision(plan: .single, rejection: .invalidStep)
            }
        }
        let requestPairs = pairs(normalized(request))
        for step in steps {
            let stepPairs = pairs(normalized(step))
            guard !stepPairs.isEmpty else { return PlanDecision(plan: .single, rejection: .invalidStep) }
            let found = stepPairs.filter { requestPairs.contains($0) }.count
            if Double(found) / Double(stepPairs.count) < minGrounding { return PlanDecision(plan: .single, rejection: .ungrounded) }
        }
        return PlanDecision(plan: .steps(steps), rejection: nil)
    }

    /// 出力から、JSON の文字列の配列を取り出す（考えの部分・コードの囲み・前後の文は、読み捨てる）。読めなければ nil。
    static func parse(_ output: String) -> [String]? {
        let text = output.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close,
              let data = String(text[open...close]).data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func key(_ step: String) -> String { String(normalized(step)) }

    /// 比べるための形：互換文字をそろえ、小文字にし、空白・句読点・記号を除く。
    static func normalized(_ text: String) -> [Character] {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .filter { !$0.isWhitespace && !$0.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.union(.symbols).contains($0) } }
            .map { $0 }
    }

    private static func pairs(_ chars: [Character]) -> Set<String> {
        guard chars.count >= 2 else { return [] }
        return Set((0..<(chars.count - 1)).map { String([chars[$0], chars[$0 + 1]]) })
    }
}

/// 複数ステップに分けるか（設定 `multiStep`）。
public enum PlanPreference {
    /// 既定：分ける（言語モデルが、分けてよいか決める）。`vc plan off` で、いまの 1 依頼 = 1 スキルの動きに戻る。
    public static let defaultEnabled = true
    public static func isEnabled(setting: Bool?) -> Bool { setting ?? defaultEnabled }
}

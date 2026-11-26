import Foundation
import VCCore

/// スキルが持つ、**言い方の規則**（フロントマター `triggers`）：依頼が、どれかの正規表現に当たれば、そのスキルの「呼び出し」とみなす（`SkillResolver`）。
/// Tiny-Jev は、説明の言葉（領域：音楽・画面…）で選ぶので、**言い方**（「10時に〇〇するよう予約して」）では、選べない。その規則を、**コアに書かず、スキルが宣言する**。
/// - 正規表現は、**全角の数字・空白を、そろえた**依頼（NFKC・空白なし）に、当てる（大文字・小文字は、区別しない）。「両方がある」は、先読み（`(?=.*A)(?=.*B)`）で書く。
/// - 当たるスキルが **1 つ**なら、そのスキルを選ぶ。**複数**なら、当たったスキルの中から、Tiny-Jev が選ぶ。0 なら、いつもどおり。
/// - 書けるのは、スキルの定義と同じ場所：プロジェクトのスキルは、**信頼したものだけ**が、選択肢に入る（広すぎる規則で、依頼を奪えるため、責任は、書いた人にある）。
public enum SkillTriggers {
    /// 規則の数・長さの上限（書き間違いと、重すぎる照合を、防ぐ）。
    public static let maxCount = 8
    public static let maxLength = 500

    /// 読み込みのときの検査：上限・正規表現として読めるか。問題があれば、その理由。
    static func validate(_ patterns: [String]) -> String? {
        guard patterns.count <= maxCount else { return tr("triggers が多い（\(patterns.count) 件。\(maxCount) まで）") }
        for pattern in patterns {
            guard !pattern.isEmpty, pattern.count <= maxLength else { return tr("triggers「\(pattern.prefix(20))…」が、空か、長い（\(maxLength) 文字まで）") }
            if (try? NSRegularExpression(pattern: pattern)) == nil { return tr("triggers「\(pattern.prefix(30))」が、正規表現として読めない") }
        }
        return nil
    }

    /// 依頼を、照合の形にそろえる（全角→半角・空白を除く）。
    static func normalized(_ request: String) -> String {
        request.precomposedStringWithCompatibilityMapping.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 依頼が、どれかの規則に当たるか。
    static func matches(_ request: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let text = normalized(request)
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }   // 読み込みのときに、検査済み：読めなければ、当たらない
            return regex.firstMatch(in: text, range: range) != nil
        }
    }
}

extension Skill {
    /// この依頼は、このスキルの `triggers` に当たるか。
    public func isTriggered(by request: String) -> Bool { SkillTriggers.matches(request, patterns: triggers) }
}

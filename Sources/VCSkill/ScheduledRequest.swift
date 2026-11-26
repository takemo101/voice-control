import Foundation

/// 「10時に〇〇するよう予約して」のような、**時刻を決めて、あとで実行する予約**の言い方か（**純粋**）。
/// Tiny-Jev は、「予約」より、領域の語（音楽・画面・ブラウザ）で、スキルを選ぶので、そのままだと、**予約ではなく、すぐ実行**される（測定：8 文中 0〜3 文だけが `todo-remind` に届いた）。
/// そこで、この言い方は、**コードの規則**で、`todo-remind`（の `run`）へ回す（`SkillResolver`。SPEC F77）。
/// 規則：**時刻**（「10時」「18:30」「正午」）と、**予約の印**（「〜よう予約」「〜する予約をして」「予約実行」「〜スケジュールして」「〜になったら」）の、両方がある。
/// 「19時にレストランを予約して」（よう、がない）・「会議のスケジュールを見て」（動詞でない）・時刻がない文は、含めない。
public enum ScheduledRequest {
    /// 回し先のスキル（任意のスキル。入っていない・無効なら、この規則は、働かない）。
    public static let skillName = "todo-remind"

    public static func matches(_ request: String) -> Bool { hasTime(in: request) && hasMarker(in: request) }

    /// 全角の数字・空白を、そろえる（`ｎ時`・「１０時」）。
    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
    }

    private static func hasTime(in request: String) -> Bool {
        let text = normalized(request)
        return text.contains("正午") || text.range(of: "[0-9]{1,2}(時|:[0-9]{2})", options: .regularExpression) != nil
    }

    private static func hasMarker(in request: String) -> Bool {
        let text = normalized(request)
        if text.contains("予約実行") || text.contains("になったら") { return true }
        // 「〜するよう予約して」「〜するように予約しておいて」「〜をスケジュールして」「スケジュール実行」
        // 「〜かける予約をして」「〜かけるのを予約して」：**動詞（ひらがなの終わり：る・う・く…）＋予約**。「レストランを予約」（を）・「ホテルの予約」（の）・「ご予約」は、含めない
        return text.range(of: "(よう|ように)(、)?予約|スケジュール(して|実行|しておいて)|[るうくぐすつぬぶむ](のを|を)?予約", options: .regularExpression) != nil
    }
}

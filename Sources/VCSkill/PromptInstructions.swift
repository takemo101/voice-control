import Foundation

/// 利用者が編集できる「指示」（整え方 `tidyInstructions`・要約のまとめ方 `summaryInstructions`）の、設定との行き来（**純粋**）。
/// 設定になければ（空白だけでも）既定。長すぎれば切る。**既定と同じ文は、設定に残さない**（既定が更新されたとき、追いつく）。
public enum PromptInstructions {
    /// 設定の値 → 使う指示。
    public static func resolve(setting: String?, default defaultText: String, maxLength: Int) -> String {
        let text = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? defaultText : String(text.prefix(maxLength))
    }

    /// 編集した文字 → 設定に書く値（空・既定と同じなら、`nil`＝設定から外す）。
    public static func setting(from text: String, default defaultText: String, maxLength: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == defaultText ? nil : String(trimmed.prefix(maxLength))
    }
}

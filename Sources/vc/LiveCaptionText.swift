import Foundation

/// 録音中に聞こえている文字（パネルに出す形）：確定した文字は濃く、確定前の文字は薄く出す。
struct LiveCaptionText: Equatable, Sendable {
    var confirmed: String
    var tentative: String

    var isEmpty: Bool { confirmed.isEmpty && tentative.isEmpty }

    /// パネルに収まる分だけ：**新しい言葉が見えるように、先頭から切る**（切ったら、先頭に「…」）。確定前の文字（末尾）は、できるだけ残す。
    /// - `maxCharacters`：出せる文字数（「…」を含めない）。
    func tail(maxCharacters: Int) -> (confirmed: String, tentative: String, truncated: Bool) {
        let total = confirmed.count + tentative.count
        guard total > maxCharacters else { return (confirmed, tentative, false) }
        let drop = total - maxCharacters
        if drop >= confirmed.count { return ("", String(tentative.suffix(maxCharacters)), true) }
        return (String(confirmed.dropFirst(drop)), tentative, true)
    }
}

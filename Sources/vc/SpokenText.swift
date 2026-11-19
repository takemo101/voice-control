import VCCore
import Foundation

/// 会話の答え（Markdown）を、**声で読む文**にする。記号（`#`・`**`・箇条書きの `-`・表の罫線）・コードブロック・URL は、読まない（読んでも、聞き取れない）。
/// 長い答えも、**全文**を読む：止めたいときは、Esc・ウィンドウのボタン・メニュー・トリガーを押す（`SaySpeaker`）。区切りごとの短い塊にして、止めたら、すぐ止まるようにする。
enum SpokenText {
    /// 読む塊（1 つが、`maxLength` 文字ほど以内）。読むものがなければ、空。
    static func chunks(from markdown: String, maxLength: Int = 200) -> [String] {
        var lines: [String] = []
        var inCode = false
        var skippedCode = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if MarkdownPreprocess.isFence(trimmed) { inCode.toggle(); continue }
            if inCode { skippedCode = true; continue }   // コードは、読まない（画面に出ている：最後に、そう伝える）
            guard let line = spoken(trimmed) else { continue }
            lines.append(line)
        }
        if skippedCode, !lines.isEmpty { lines.append(tr("コードは、画面に出しています。")) }
        // 行を、塊にまとめる（長い行は、句点で割る）
        var chunks: [String] = []
        var current = ""
        for line in lines.flatMap({ split($0, maxLength: maxLength) }) {
            if !current.isEmpty, current.count + line.count > maxLength { chunks.append(current); current = "" }
            current += line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// 1 行を、読む文にする。読むものがなければ nil。
    private static func spoken(_ line: String) -> String? {
        var text = line
        if text.isEmpty { return nil }
        // 表の仕切り（|---|---|）・区切り線
        if text.allSatisfy({ "|-: *_=".contains($0) }) { return nil }
        // 行頭の記号：見出し・引用・箇条書き・番号・タスク
        text = text.replacingOccurrences(of: #"^(#{1,6}\s+|>+\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        // 画像・リンク：題だけ。脚注
        text = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[\^[^\]]*\]"#, with: "", options: .regularExpression)
        // URL・HTML のタグ
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // 強調・コードの記号・表の罫線
        for mark in ["**", "__", "~~", "`", "*"] { text = text.replacingOccurrences(of: mark, with: "") }
        text = text.replacingOccurrences(of: "|", with: "、")
        text = text.replacingOccurrences(of: #"\s*、[\s、]*"#, with: "、", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "、 \t"))
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        // 行の終わりで、間をあける（句点がなければ、足す）
        if let last = text.last, !"。．.！？!?：:、".contains(last) { text += "。" }
        return text
    }

    /// 長い行を、句点などで、`maxLength` ほどに割る（句点がなければ、そのまま）。
    private static func split(_ line: String, maxLength: Int) -> [String] {
        guard line.count > maxLength else { return [line] }
        var parts: [String] = []
        var current = ""
        for character in line {
            current.append(character)
            if "。！？!?".contains(character), current.count >= maxLength / 2 { parts.append(current); current = "" }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

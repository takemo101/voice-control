import Foundation

/// **英語の文字を、単語のすぐあとに入れるときの、空白**（設定 `smartSpacing`。Hex の「Smart spacing」と同じ考え方）。
/// 認識した文字は、前後の空白を持たない：前の文字に、そのまま続けて入れると、`hello` のあとに `world` が、`helloworld` になる。
/// **足すのは、前の文字が、英数字か、文の区切り（`. , ; : ! ? ) ] } " ' %`）で、入れる文字が、英数字で始まるときだけ**。日本語（かな・漢字）の前後・空白・改行の後・開き括弧のあとには、足さない。**純粋**。
public enum SmartSpacing {
    /// `before`：入れる場所の、直前の 1 文字（読めなければ nil：足さない）。
    public static func adjusted(_ text: String, before: Character?) -> String {
        guard let before, let first = text.first, startsWord(first), endsWordOrSentence(before) else { return text }
        return " " + text
    }

    private static func startsWord(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    private static func endsWordOrSentence(_ c: Character) -> Bool {
        if c.isASCII && (c.isLetter || c.isNumber) { return true }
        return ".,;:!?)]}\"'%”’".contains(c)
    }
}

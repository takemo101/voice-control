import AppKit

/// Markdown の整形（`MarkdownRenderer`）が使う、色（暗いガラスの上の、白系）。デザインを、1 か所で揃える。
@MainActor enum HUDStyle {
    /// 補足の文字の色。
    static let secondary = NSColor(white: 1, alpha: 0.62)
    /// 本文の文字の色。
    static let primary = NSColor(white: 1, alpha: 0.92)
    /// 線・面の、薄い白。
    static func hairline(_ alpha: CGFloat = 0.14) -> NSColor { NSColor(white: 1, alpha: alpha) }
}

import AppKit

/// 画面の上のパネル（`HUD`）と、Markdown のウィンドウ（`MarkdownWindow`）が共有する、見た目（暗いガラス・角丸・色・小さなラベル）。デザインを、1 か所で揃える。
@MainActor enum HUDStyle {
    /// 補足の文字の色。
    static let secondary = NSColor(white: 1, alpha: 0.62)
    /// 本文の文字の色。
    static let primary = NSColor(white: 1, alpha: 0.92)
    /// 線・面の、薄い白。
    static func hairline(_ alpha: CGFloat = 0.14) -> NSColor { NSColor(white: 1, alpha: alpha) }
    static let cornerRadius: CGFloat = 18

    /// 暗いガラスの背景（角丸・細い縁）。ウィンドウの背景の明るさに関わらず、同じ見た目（`vibrantDark`）。
    static func glassBackground() -> NSVisualEffectView {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        return background
    }

    /// 小さな丸いラベル（スキル名・トリガーの名前など）。
    static func pill(_ text: String, fg: NSColor, bg: NSColor) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = fg
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = bg.cgColor
        box.layer?.cornerRadius = 9
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            field.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
        box.setContentHuggingPriority(.required, for: .horizontal)
        return box
    }
}

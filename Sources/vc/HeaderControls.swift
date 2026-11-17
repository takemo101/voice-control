import SwiftUI

/// 見出しの右に並べる、丸いアイコンのボタン（**会話・画像・拡大の窓で、共通**）。文字は付けない（折り返さない）：何をするかは、押す前の説明（`help`）。
/// - `accent`：主な操作（コピーなど。水色の面）。`active`：開いている状態（文字起こしの欄など）。`flashed`：押したあと、少しの間、チェック。
/// - `cancel`：Esc を、このボタンが受ける（`.cancelAction`。最初の応答者が、どこでも、効く）。
struct HeaderIconButton: View {
    let symbol: String
    let help: String
    var accent = false
    var active = false
    var flashed = false
    var cancel = false
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        let button = Button(action: action) {
            HeaderCircle(symbol: symbol, accent: accent, active: active, flashed: flashed, hovering: hover.on)
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
        .onHover { hover.on = $0 }
        if cancel { button.keyboardShortcut(.cancelAction) } else { button }
    }
}

/// 丸いアイコンの見た目（`Menu` のラベルにも使う）。
struct HeaderCircle: View {
    let symbol: String
    var accent = false
    var active = false
    var flashed = false
    var hovering = false

    var body: some View {
        let tint = DocumentPalette.accent
        Image(systemName: flashed ? "checkmark" : symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(flashed ? tint : (accent || active ? .white : .white.opacity(0.85)))
            .frame(width: 28, height: 28)
            .background(Circle().fill(accent || active ? tint.opacity(hovering ? 0.42 : (active ? 0.34 : 0.30)) : .white.opacity(hovering ? 0.22 : 0.10)))
            .overlay(Circle().strokeBorder(accent || active ? tint.opacity(hovering ? 0.75 : 0.5) : .white.opacity(0.14), lineWidth: 0.7))
            .contentShape(Circle())
    }
}

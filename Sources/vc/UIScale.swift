import os
import SwiftUI
import VCCore

/// 画面の文字の大きさ（設定 `fontSize`。標準は 13・範囲は 10〜24）。**倍率は、標準に対する割合**（13 → 1.0・19.5 → 1.5）：会話・Markdown のウィンドウ・上のパネル・画像の窓・拡大の窓の、文字の大きさに、掛ける。設定ウィンドウ自身は、対象外（OS 標準の部品）。
/// 画面の文字は、`vcFont`（SwiftUI）と `MarkdownRenderer`（本文）が、この倍率を使う。変えると、開いている画面が、すぐ変わる（`UIScale.shared` を見ている：`userScaled()`）。
@MainActor final class UIScale: ObservableObject {
    static let shared = UIScale()
    nonisolated static let standard = 13
    nonisolated static let range = 10...24

    @Published private(set) var size: Int

    private init() {
        size = Self.stored()
        Self.publish(size)
    }

    var factor: CGFloat { Self.factor(for: size) }

    /// 標準に対する倍率（範囲の外は、端に寄せる）。
    nonisolated static func factor(for size: Int) -> CGFloat { CGFloat(clamp(size)) / CGFloat(standard) }
    nonisolated static func clamp(_ size: Int) -> Int { min(range.upperBound, max(range.lowerBound, size)) }

    /// 設定を読み直す（設定を変えたあと・画面を開くとき。別のプロセスの画面〔`vc show`・画像の窓〕は、起動のときに読む）。
    func reload() { apply(Self.stored()) }

    /// 大きさを決める（設定の読み直しと、テスト）。
    func apply(_ newSize: Int) {
        let next = Self.clamp(newSize)
        guard next != size else { return }
        Self.publish(next)   // 先に写しを替える（`size` の変化を受けた側が、新しい値を読む）
        size = next
    }

    private static func stored() -> Int { clamp(Settings.loadOrDefault().settings.fontSize ?? standard) }

    // どのスレッドからも読める写し（`NSAttributedString` の組み立て・高さの記憶の鍵）
    private nonisolated static let mirror = OSAllocatedUnfairLock(initialState: 13)
    private nonisolated static func publish(_ size: Int) { mirror.withLock { $0 = size } }
    nonisolated static var currentSize: Int { mirror.withLock { $0 } }
    nonisolated static var currentFactor: CGFloat { factor(for: currentSize) }
}

private struct FontScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    /// 文字の倍率（`userScaled()` が入れる。入れていない画面は、1）。
    var fontScale: CGFloat {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

/// 倍率を、環境に入れる（`UIScale.shared` を見ているので、設定が変わると、中の画面が、すぐ描き直される）。
private struct UserScale: ViewModifier {
    @ObservedObject private var scale = UIScale.shared
    func body(content: Content) -> some View { content.environment(\.fontScale, scale.factor) }
}

/// 倍率を掛けた、システムの書体。
private struct ScaledFont: ViewModifier {
    @Environment(\.fontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool
    /// 倍率の上限（見出しの札・ボタンの文字など、決まった幅に収めたい所）。なければ、設定のまま。
    let maxScale: CGFloat?

    func body(content: Content) -> some View {
        let font = Font.system(size: size * min(scale, maxScale ?? scale), weight: weight, design: design)
        return content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    /// 画面の根（`NSHostingView` の中身）に付ける：文字の倍率（設定 `fontSize`）を、中の `vcFont` へ渡す。
    func userScaled() -> some View { modifier(UserScale()) }

    /// `.font(.system(size:weight:design:))` の代わり：設定の倍率（標準 13 に対する割合）を掛ける。
    /// `maxScale`：この倍率までしか、大きくしない（見出しの札など、決まった幅に収めたい所）。
    func vcFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, monospacedDigit: Bool = false, maxScale: CGFloat? = nil) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, monospacedDigit: monospacedDigit, maxScale: maxScale))
    }
}

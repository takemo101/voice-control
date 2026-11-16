import CoreGraphics
import Foundation

/// 拡大の窓の、倍率の計算（**純粋**：画面・ウィンドウから離して確かめられる）。倍率 1 ＝ 等倍（元の大きさ）。
enum ZoomMath {
    static let minimum: CGFloat = 0.1
    static let maximum: CGFloat = 8
    /// 「＋」「−」で止まる倍率（Preview・ブラウザの段）。
    static let steps: [CGFloat] = [0.1, 0.125, 0.15, 0.2, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8]

    /// 画像の全体が、表示の領域（`viewport`）に、`margin` の余白つきで入る倍率。**拡大はしない**（小さい画像は、等倍のまま）。
    static func fit(image: CGSize, viewport: CGSize, margin: CGFloat = 20) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        let width = (viewport.width - 2 * margin) / image.width
        let height = (viewport.height - 2 * margin) / image.height
        return max(0.01, min(1, width, height))
    }

    /// 次の段（`direction` が正：拡大・負：縮小）。上限・下限で止まる。
    static func step(from magnification: CGFloat, direction: Int) -> CGFloat {
        if direction > 0 { return steps.first { $0 > magnification * 1.01 } ?? maximum }
        return steps.last { $0 < magnification / 1.01 } ?? minimum
    }

    /// ダブルクリック：全体表示 ⇄ 等倍（すでに等倍に近い全体表示なら、2 倍）。
    static func doubleClickTarget(current: CGFloat, fit: CGFloat) -> CGFloat {
        abs(current - fit) < 0.02 ? (fit < 0.98 ? 1 : 2) : fit
    }

    static func clamp(_ magnification: CGFloat, lowerBound: CGFloat = minimum) -> CGFloat {
        min(maximum, max(min(lowerBound, minimum), magnification))
    }

    /// 画面に出す倍率（例：「62%」）。
    static func percent(_ magnification: CGFloat) -> String { "\(Int((magnification * 100).rounded()))%" }
}

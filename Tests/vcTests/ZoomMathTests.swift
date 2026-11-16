import CoreGraphics
import Testing
@testable import vc

/// 拡大の窓の、倍率の計算。
@Suite struct ZoomMathTests {
    @Test func fitShrinksALargeImageToTheViewportWithMarginAndNeverEnlargesASmallOne() {
        #expect(ZoomMath.fit(image: CGSize(width: 1000, height: 500), viewport: CGSize(width: 540, height: 400), margin: 20) == 0.5)   // 幅が決める
        #expect(ZoomMath.fit(image: CGSize(width: 500, height: 1000), viewport: CGSize(width: 900, height: 540), margin: 20) == 0.5)   // 高さが決める
        #expect(ZoomMath.fit(image: CGSize(width: 100, height: 80), viewport: CGSize(width: 900, height: 600)) == 1)                   // 拡大しない
        #expect(ZoomMath.fit(image: CGSize(width: 0, height: 0), viewport: CGSize(width: 900, height: 600)) == 1)                      // 壊れた画像
        #expect(ZoomMath.fit(image: CGSize(width: 1000, height: 1000), viewport: CGSize(width: 10, height: 10)) == 0.01)               // 領域がない：下限
    }

    @Test func stepsMoveToTheNextRungAndStopAtTheLimits() {
        #expect(ZoomMath.step(from: 1, direction: 1) == 1.25)
        #expect(ZoomMath.step(from: 1, direction: -1) == 0.75)
        #expect(ZoomMath.step(from: 0.62, direction: 1) == 0.67)       // 全体表示の途中の倍率からも、次の段へ
        #expect(ZoomMath.step(from: 0.62, direction: -1) == 0.5)
        #expect(ZoomMath.step(from: 8, direction: 1) == 8)             // 上限
        #expect(ZoomMath.step(from: 0.1, direction: -1) == 0.1)        // 下限
        // 「＋」を押し続けると、必ず、上限まで進む（同じ値で止まらない）
        var m: CGFloat = 0.1
        for _ in 0..<40 { let next = ZoomMath.step(from: m, direction: 1); if next == m { break }; #expect(next > m); m = next }
        #expect(m == ZoomMath.maximum)
    }

    @Test func doubleClickTogglesBetweenFitAndActualAndDoublesAnAlreadyActualFit() {
        #expect(ZoomMath.doubleClickTarget(current: 0.5, fit: 0.5) == 1)     // 全体表示 → 等倍
        #expect(ZoomMath.doubleClickTarget(current: 1, fit: 0.5) == 0.5)     // 等倍 → 全体表示
        #expect(ZoomMath.doubleClickTarget(current: 2.5, fit: 0.5) == 0.5)
        #expect(ZoomMath.doubleClickTarget(current: 1, fit: 1) == 2)         // 小さい画像：全体表示が等倍 → 2 倍
        #expect(ZoomMath.doubleClickTarget(current: 2, fit: 1) == 1)
    }

    @Test func percentRoundsAndClampKeepsTheRange() {
        #expect(ZoomMath.percent(0.625) == "63%")   // 四捨五入
        #expect(ZoomMath.percent(1) == "100%" && ZoomMath.percent(7.999) == "800%")
        #expect(ZoomMath.clamp(20) == 8)
        #expect(ZoomMath.clamp(0.001) == 0.1)
        #expect(ZoomMath.clamp(0.01, lowerBound: 0.02) == 0.02)   // 全体表示が、下限より小さい（巨大な画像）ときは、その倍率まで許す
        #expect(ZoomMath.clamp(0.01, lowerBound: 0.5) == 0.1)    // 下限は、広げるだけ（狭めない）
    }
}

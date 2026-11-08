import CoreGraphics
import Testing
@testable import vc

/// 範囲選択の幾何：修飾キーでの形・クリックとドラッグの見分け・複数ディスプレイでの座標・切り抜く枠・拡大の段。
@Suite struct ScreenGeometryTests {
    @Test func dragInAnyDirectionGivesTheSameRect() {
        let a = ScreenGeometry.selectionRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250), square: false, fromCenter: false)
        let b = ScreenGeometry.selectionRect(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 100), square: false, fromCenter: false)
        #expect(a == CGRect(x: 100, y: 100, width: 200, height: 150) && a == b)
    }

    @Test func shiftMakesASquareFollowingTheLongerSide() {
        let up = ScreenGeometry.selectionRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 150), square: true, fromCenter: false)
        #expect(up == CGRect(x: 100, y: 100, width: 200, height: 200))
        let toTopLeft = ScreenGeometry.selectionRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 80, y: 20), square: true, fromCenter: false)
        #expect(toTopLeft == CGRect(x: 20, y: 20, width: 80, height: 80))   // 左上へ向かうので、始点が、右下の角
    }

    @Test func optionGrowsFromTheStartPoint() {
        let r = ScreenGeometry.selectionRect(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 250, y: 230), square: false, fromCenter: true)
        #expect(r == CGRect(x: 150, y: 170, width: 100, height: 60) && r.midX == 200 && r.midY == 200)
    }

    @Test func clampKeepsTheSelectionInsideTheScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(ScreenGeometry.clamp(CGRect(x: -50, y: 500, width: 200, height: 200), to: bounds) == CGRect(x: 0, y: 500, width: 150, height: 100))
        #expect(ScreenGeometry.clamp(CGRect(x: 900, y: 0, width: 10, height: 10), to: bounds) == .zero)
    }

    @Test func aSmallMovementIsAClick() {
        #expect(ScreenGeometry.isClick(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 11)))
        #expect(!ScreenGeometry.isClick(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 20, y: 10)))
    }

    @Test func theFrontWindowUnderThePointWins() {
        let front = ScreenGeometry.PickableWindow(id: 1, frame: CGRect(x: 100, y: 100, width: 200, height: 200), title: "前")
        let back = ScreenGeometry.PickableWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "奥")
        #expect(ScreenGeometry.window(at: CGPoint(x: 150, y: 150), in: [front, back])?.id == 1)
        #expect(ScreenGeometry.window(at: CGPoint(x: 50, y: 50), in: [front, back])?.id == 2)
        #expect(ScreenGeometry.window(at: CGPoint(x: 900, y: 50), in: [front, back]) == nil)
    }

    /// 主ディスプレイ 1440×900 の右に、2 台目（原点が x=1440。下端が、主と同じ）。ウィンドウサーバーの座標は、左上が原点。
    @Test func windowServerRectsBecomeViewRectsOnEachScreen() {
        let mainHeight: CGFloat = 900
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let side = CGRect(x: 1440, y: 0, width: 1920, height: 1080)   // Cocoa の座標：下端が揃うので、上端は 1080
        // 主ディスプレイの左上の、100×50 のウィンドウ
        let onMain = ScreenGeometry.viewRect(fromWindowServer: CGRect(x: 0, y: 0, width: 100, height: 50), mainScreenHeight: mainHeight, screenFrame: main)
        #expect(onMain == CGRect(x: 0, y: 0, width: 100, height: 50))
        // 2 台目の左上（ウィンドウサーバーの座標では、x=1440・y=-180）
        let onSide = ScreenGeometry.viewRect(fromWindowServer: CGRect(x: 1440, y: -180, width: 300, height: 200), mainScreenHeight: mainHeight, screenFrame: side)
        #expect(onSide == CGRect(x: 0, y: 0, width: 300, height: 200))
        // 2 台目で、ビューの左上から 100 下・50 右
        let inside = ScreenGeometry.viewRect(fromWindowServer: CGRect(x: 1490, y: -80, width: 10, height: 10), mainScreenHeight: mainHeight, screenFrame: side)
        #expect(inside == CGRect(x: 50, y: 100, width: 10, height: 10))
    }

    @Test func pixelSizeFollowsTheScale() {
        #expect(ScreenGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 500, height: 150), scale: 2) == (1000, 300))
        #expect(ScreenGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 333.3, height: 100), scale: 1).width == 333)
    }

    @Test func cropRectScalesToPixelsAndStaysInsideTheImage() {
        let r = ScreenGeometry.cropRect(selection: CGRect(x: 10, y: 20, width: 100, height: 50), viewSize: CGSize(width: 800, height: 600), imageSize: CGSize(width: 1600, height: 1200))
        #expect(r == CGRect(x: 20, y: 40, width: 200, height: 100))
        let edge = ScreenGeometry.cropRect(selection: CGRect(x: 790, y: 590, width: 20, height: 20), viewSize: CGSize(width: 800, height: 600), imageSize: CGSize(width: 1600, height: 1200))
        #expect(edge == CGRect(x: 1580, y: 1180, width: 20, height: 20))
    }

    @Test func aspectIsShownOnlyForSimpleRatios() {
        #expect(ScreenGeometry.aspectLabel(width: 1920, height: 1080) == "16:9")
        #expect(ScreenGeometry.aspectLabel(width: 1000, height: 300) == "10:3")
        #expect(ScreenGeometry.aspectLabel(width: 1013, height: 307) == nil)
    }

    @Test func zoomMovesOneStepAtATime() {
        #expect(ScreenGeometry.zoom(8, scrollDelta: 1) == 12)
        #expect(ScreenGeometry.zoom(8, scrollDelta: -1) == 6)
        #expect(ScreenGeometry.zoom(24, scrollDelta: 3) == 24)
        #expect(ScreenGeometry.zoom(4, scrollDelta: -3) == 4)
        #expect(ScreenGeometry.zoom(8, scrollDelta: 0) == 8)
        #expect(ScreenGeometry.hex(red: 255, green: 0, blue: 128) == "#FF0080")
    }
}

import AppKit
import Testing
@testable import vc

/// パネル・ウィンドウは、いま使っている画面（マウスのある画面）に出す。ディスプレイが複数でも、見える。
@Suite struct ScreenPlacementTests {
    // 左の大きなディスプレイと、その右の縦長のディスプレイ（実際の並びに近い）
    private let main = NSRect(x: 0, y: 0, width: 2560, height: 1440)
    private let side = NSRect(x: 2560, y: 0, width: 1066, height: 1600)

    @Test func thePointerPicksTheScreenItIsOn() {
        #expect(ScreenPlacement.index(containing: NSPoint(x: 700, y: 150), in: [main, side]) == 0)
        #expect(ScreenPlacement.index(containing: NSPoint(x: 3000, y: 900), in: [main, side]) == 1)
        #expect(ScreenPlacement.index(containing: NSPoint(x: -50, y: 10), in: [main, side]) == nil)   // どの画面にもない
    }

    @Test func theHudSitsAtTheTopCenterOfTheVisibleAreaOfThatScreen() {
        let visible = NSRect(x: 2560, y: 0, width: 1066, height: 1560)   // メニューバーなどを除いた領域
        let frame = ScreenPlacement.hudFrame(in: visible, width: 468, height: 146)
        #expect(frame == NSRect(x: 2560 + 533 - 234, y: 1560 - 146 - 16, width: 468, height: 146))
        #expect(visible.contains(frame))   // 画面からはみ出さない
    }

    @Test func aWindowIsCenteredInTheVisibleArea() {
        let frame = ScreenPlacement.centeredFrame(size: NSSize(width: 660, height: 600), in: side)
        #expect(frame.midX == side.midX && frame.midY == side.midY && frame.size == NSSize(width: 660, height: 600))
    }
}

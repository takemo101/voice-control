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

    // MARK: 会話・Markdown のウィンドウと、上のパネル（HUD）が、重ならない配置

    private let chatSize = NSSize(width: 640, height: 720), chatMin = NSSize(width: 420, height: 380)
    private func visible(_ width: CGFloat, _ height: CGFloat) -> NSRect { NSRect(x: 0, y: 0, width: width, height: height) }

    @Test func aBigScreenKeepsTheWindowCenteredBecauseTheTopBandIsFree() {
        let area = visible(1728, 1600)
        let frame = ScreenPlacement.windowFrame(size: chatSize, minSize: chatMin, in: area)
        #expect(frame == ScreenPlacement.centeredFrame(size: chatSize, in: area))
    }

    @Test func aSmallerScreenMovesTheWindowBelowTheTopBandAndShrinksItsHeightIfNeeded() {
        // 使える高さ 860（13 インチ級）：真ん中だと、上の空きが 70 で、確認パネル（約 190）に、かかる
        let laptop = visible(1440, 860)
        let frame = ScreenPlacement.windowFrame(size: chatSize, minSize: chatMin, in: laptop)
        #expect(frame.maxY <= laptop.maxY - ScreenPlacement.hudReserve)           // 上の帯に、かからない
        #expect(frame.minY >= laptop.minY && frame.height == 608)                // 高さを、領域（640）から余白（32）を引いた分へ縮める
        #expect(frame.midX == laptop.midX)
        // もっと低い画面（700）：さらに縮む。ただし、最小の高さまで
        let low = ScreenPlacement.windowFrame(size: chatSize, minSize: chatMin, in: visible(1280, 700))
        #expect(low.maxY <= 700 - ScreenPlacement.hudReserve && low.height == 448)   // 領域 480 − 余白 32
    }

    @Test func aScreenTooLowForTheMinimumKeepsTheWindowOnScreenEvenIfItTouchesTheBand() {
        let tiny = visible(1024, 500)
        let frame = ScreenPlacement.windowFrame(size: chatSize, minSize: chatMin, in: tiny)
        #expect(frame.height == chatMin.height)   // 最小の高さを守る
        #expect(frame.minY >= tiny.minY)                                         // 画面の下から、はみ出さない
    }

    @Test func aNarrowScreenShrinksTheWidthButNotBelowTheMinimum() {
        #expect(ScreenPlacement.windowFrame(size: chatSize, minSize: chatMin, in: visible(500, 1400)).width == 468)   // 500 − 余白 32
        #expect(ScreenPlacement.windowFrame(size: chatSize, minSize: chatMin, in: visible(380, 1400)).width == 420)   // 最小の幅
    }

    @Test func theWindowNeverOverlapsTheBandWheneverTheMinimumHeightFits() {
        for height in stride(from: 640.0, through: 2200.0, by: 20.0) {   // 領域が、最小の高さ（380）＋帯（220）＋余白に、収まる高さ
            let area = visible(1440, CGFloat(height))
            let frame = ScreenPlacement.windowFrame(size: chatSize, minSize: chatMin, in: area)
            #expect(frame.maxY <= area.maxY - ScreenPlacement.hudReserve, "高さ \(height)")
            #expect(area.contains(NSPoint(x: frame.midX, y: frame.midY)) && frame.minY >= area.minY)
        }
    }

    @Test func theDevOverrideShrinksTheVisibleAreaToTheTopCenterAndIgnoresBadValues() {
        let real = visible(2560, 1400)
        let small = ScreenPlacement.limited(real, to: "1280x700")
        #expect(small == NSRect(x: 640, y: 700, width: 1280, height: 700))                 // 上の中央
        #expect(ScreenPlacement.limited(real, to: "9999X9999") == real)                    // 大きすぎる値は、本物の領域まで（大文字の X も可）
        for bad in [nil, "", "abc", "1280", "100x100", "1280x", "x700"] as [String?] { #expect(ScreenPlacement.limited(real, to: bad) == real, "無視：\(bad ?? "nil")") }
    }
}


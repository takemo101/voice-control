import AppKit

/// パネル・ウィンドウを、**いま使っている画面**（マウスのある画面）に出す。ディスプレイが複数あるとき、`NSScreen.main`（メニューバーのある画面）に出すと、別のディスプレイを使っている利用者に、見えない。
/// 計算は、画面の枠を渡す純粋な関数（`NSScreen` に依らず、確かめられる）。
enum ScreenPlacement {
    /// 点（マウスの位置。画面の座標）を含む画面の番号。どこにもなければ nil。
    static func index(containing point: NSPoint, in frames: [NSRect]) -> Int? {
        frames.firstIndex { NSMouseInRect(point, $0, false) }
    }

    /// 画面の上の中央に出すパネルの枠（`visible`：メニューバー・Dock を除いた領域）。
    static func hudFrame(in visible: NSRect, width: CGFloat, height: CGFloat, margin: CGFloat = 16) -> NSRect {
        NSRect(x: visible.midX - width / 2, y: visible.maxY - height - margin, width: width, height: height)
    }

    /// 領域の真ん中に置く枠。
    static func centeredFrame(size: NSSize, in visible: NSRect) -> NSRect {
        NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// いま使っている画面：マウスのある画面。なければ、メニューバーのある画面・最初の画面。
    @MainActor static func current() -> NSScreen? {
        let screens = NSScreen.screens
        if let i = index(containing: NSEvent.mouseLocation, in: screens.map(\.frame)) { return screens[i] }
        return NSScreen.main ?? screens.first
    }

    /// 画面の、使える領域（画面がなければ、既定の大きさ）。
    @MainActor static func currentVisibleFrame() -> NSRect {
        current()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

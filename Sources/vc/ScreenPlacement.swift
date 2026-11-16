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

    /// **上のパネル（`HUD`）のために、上に空けておく高さ**：上端の余白（16）＋確認パネルの、ふつうの高さ（約 190。撮った画像からの概算）＋余白。小さい画面で、会話・Markdown のウィンドウが、確認のボタンを、覆わないように。
    static let hudReserve: CGFloat = 220
    /// 会話・Markdown のウィンドウの、画面の端との余白。
    static let windowMargin: CGFloat = 16

    /// 会話・Markdown のウィンドウの枠（`size`：出したい大きさ・`minSize`：縮められる限度・`visible`：使える領域）。
    /// 画面の真ん中に置いて、上の帯（`hudReserve`）に、かからなければ、そのまま。**かかるとき**（小さい画面）は、帯の下の領域の真ん中に置き、**高さを、領域に収まるまで縮める**（`minSize` まで）。縮めても、中は、スクロールできる。
    /// 領域が、`minSize` にも足りない画面では、画面の下から、はみ出さない位置に置く（帯に、かかる：避けられない）。
    static func windowFrame(size: NSSize, minSize: NSSize, in visible: NSRect, reserve: CGFloat = hudReserve) -> NSRect {
        let width = min(size.width, max(minSize.width, visible.width - 2 * windowMargin))
        let centered = centeredFrame(size: NSSize(width: width, height: min(size.height, visible.height)), in: visible)
        if centered.maxY <= visible.maxY - reserve { return centered }
        let region = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: max(0, visible.height - reserve))
        let height = max(minSize.height, min(size.height, region.height - 2 * windowMargin))
        var frame = centeredFrame(size: NSSize(width: width, height: height), in: region)
        frame.origin.y = max(frame.origin.y, visible.minY)
        return frame
    }

    /// 開発用：環境変数 `VC_VISIBLE_SIZE`（`幅x高さ`。例：`1280x700`）で、使える領域を、小さく見せる（上の中央に寄せる）。**大きな画面で、小さな画面の配置を、実物のウィンドウで確かめるため**。不正な値・大きすぎる値は、無視（本物の領域のまま）。
    static func limited(_ visible: NSRect, to spec: String?) -> NSRect {
        guard let spec, let x = spec.lowercased().firstIndex(of: "x"),
              let width = Double(spec[..<x]), let height = Double(spec[spec.index(after: x)...]), width >= 300, height >= 300 else { return visible }
        let w = min(CGFloat(width), visible.width), h = min(CGFloat(height), visible.height)
        return NSRect(x: visible.midX - w / 2, y: visible.maxY - h, width: w, height: h)
    }

    /// 画面の、使える領域（メニューバー・Dock を除く。開発用の上書きを含む）。
    @MainActor static func visibleFrame(of screen: NSScreen) -> NSRect {
        limited(screen.visibleFrame, to: ProcessInfo.processInfo.environment["VC_VISIBLE_SIZE"])
    }

    /// いま使っている画面：マウスのある画面。なければ、メニューバーのある画面・最初の画面。
    @MainActor static func current() -> NSScreen? {
        let screens = NSScreen.screens
        if let i = index(containing: NSEvent.mouseLocation, in: screens.map(\.frame)) { return screens[i] }
        return NSScreen.main ?? screens.first
    }

    /// 画面の、使える領域（画面がなければ、既定の大きさ）。
    @MainActor static func currentVisibleFrame() -> NSRect {
        current().map(visibleFrame(of:)) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

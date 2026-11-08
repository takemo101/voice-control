import CoreGraphics
import Foundation

/// 範囲選択の幾何（画面・マウスに依らない純粋な計算）。座標は、特に断らない限り、**画面の上のビュー**の座標（左上が原点・単位はポイント）。
enum ScreenGeometry {
    /// 点とみなす動きの大きさ（ポイント）：これより小さければ、クリック（ウィンドウを選ぶ）。
    static let clickSlop: CGFloat = 4
    /// 選択として扱う最小の大きさ（ポイント）。
    static let minimumSelection: CGFloat = 2

    struct PickableWindow: Equatable {
        let id: CGWindowID
        /// ビューの座標での枠。
        let frame: CGRect
        /// 「アプリ名」（画面収録の許可があれば、ウィンドウの題名も）。
        let title: String
    }

    /// ドラッグの始点から終点までの選択の枠。`square`（Shift）：正方形・`fromCenter`（Option）：始点を中心にする。
    static func selectionRect(from start: CGPoint, to end: CGPoint, square: Bool, fromCenter: Bool) -> CGRect {
        var dx = end.x - start.x, dy = end.y - start.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCenter { return CGRect(x: start.x - abs(dx), y: start.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2) }
        return CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy))
    }

    /// `bounds` の中に収める（はみ出した分は、削る）。
    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let clipped = rect.intersection(bounds)
        return clipped.isNull ? .zero : clipped
    }

    /// 始点と終点が近い＝クリック。
    static func isClick(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) < clickSlop
    }

    /// 点の下にある、いちばん手前のウィンドウ（`windows` は、手前から奥の順）。
    static func window(at point: CGPoint, in windows: [PickableWindow]) -> PickableWindow? {
        windows.first { $0.frame.contains(point) }
    }

    /// ウィンドウサーバーの座標（全画面の座標。原点は、主ディスプレイの左上）の枠を、ある画面のビューの座標にする。
    /// - `mainScreenHeight`：主ディスプレイの高さ。`screenFrame`：その画面の枠（Cocoa の座標。原点は、主ディスプレイの左下）。
    static func viewRect(fromWindowServer bounds: CGRect, mainScreenHeight: CGFloat, screenFrame: CGRect) -> CGRect {
        let cocoaMaxY = mainScreenHeight - bounds.minY
        return CGRect(x: bounds.minX - screenFrame.minX, y: screenFrame.maxY - cocoaMaxY, width: bounds.width, height: bounds.height)
    }

    /// ポイントの枠の、ピクセルでの大きさ。
    static func pixelSize(of rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }

    /// 画像（ピクセル）から切り抜く枠：ビューの選択（ポイント）を、画像の大きさに合わせて拡大し、整数にして、画像の中に収める。
    static func cropRect(selection: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let sx = imageSize.width / viewSize.width, sy = imageSize.height / viewSize.height
        let rect = CGRect(x: selection.minX * sx, y: selection.minY * sy, width: selection.width * sx, height: selection.height * sy).integral
        return clamp(rect, to: CGRect(origin: .zero, size: imageSize))
    }

    /// 縦横の比（小さな整数で言えるときだけ。例：16:9）。
    static func aspectLabel(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        let divisor = gcd(width, height)
        let w = width / divisor, h = height / divisor
        return w <= 21 && h <= 21 ? "\(w):\(h)" : nil
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    // MARK: 拡大鏡

    static let zoomSteps: [CGFloat] = [4, 6, 8, 12, 16, 24]
    static let defaultZoom: CGFloat = 8

    /// 拡大の倍率を、ホイールの向きで、1 段ずつ変える（上へ回すと拡大）。
    static func zoom(_ current: CGFloat, scrollDelta: CGFloat) -> CGFloat {
        guard scrollDelta != 0 else { return current }
        let index = zoomSteps.enumerated().min { abs($0.element - current) < abs($1.element - current) }?.offset ?? 2
        let next = max(0, min(zoomSteps.count - 1, index + (scrollDelta > 0 ? 1 : -1)))
        return zoomSteps[next]
    }

    static func hex(red: UInt8, green: UInt8, blue: UInt8) -> String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

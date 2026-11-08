import AppKit
import CoreGraphics

/// 範囲選択の画面の部品：案内の状態・ディスプレイ 1 つを覆うパネル・選択の面（`SelectorView`）。流れ（撮る・終わる・キー）は、`ScreenSelector`。描く物は、`ChromeView`（`ScreenSelectorChrome.swift`）。

// MARK: - 案内の状態（SwiftUI の `@State` は、この環境では使えない）

@MainActor final class GuideState: ObservableObject {
    @Published var loupe = false
}

// MARK: - パネル

/// ディスプレイ 1 つを覆う、枠のないパネル。
final class SelectorPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var selectorView: SelectorView { contentView as! SelectorView }
}

// MARK: - ビュー

/// 1 つのディスプレイの、選択の面。下に、静止画（レイヤーに 1 回だけ置く）・上に、暗い覆いと、枠・ことば・拡大鏡（`ChromeView`）。
@MainActor final class SelectorView: NSView {
    weak var controller: ScreenSelector?
    let displayID: CGDirectDisplayID
    let image: CGImage
    private let windows: [ScreenGeometry.PickableWindow]
    private let chrome: ChromeView
    private var dragOrigin: CGPoint?
    private var lastDrag = CGPoint.zero
    private var selection = CGRect.zero
    private var hover: ScreenGeometry.PickableWindow?
    private var pointer: CGPoint?
    private var highlight = CGRect.zero   // 光る枠（目標へ、なめらかに近づく）
    private var timer: Timer?
    private var flashRect: CGRect?
    private var flashAlpha: CGFloat = 0

    var isDragging: Bool { dragOrigin != nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(controller: ScreenSelector?, displayID: CGDirectDisplayID, image: CGImage, windows: [ScreenGeometry.PickableWindow], visibleBottom: CGFloat, guide: GuideState) {
        self.controller = controller
        self.displayID = displayID
        self.image = image
        self.windows = windows
        chrome = ChromeView(guide: guide, visibleBottom: visibleBottom)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        chrome.owner = self
        chrome.autoresizingMask = [.width, .height]
        addSubview(chrome)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override func layout() {
        super.layout()
        chrome.frame = bounds
    }

    /// 画像のピクセルとポイントの比。
    var scale: CGFloat { CGFloat(image.width) / max(1, bounds.width) }

    // MARK: ポインタ

    func refreshPointer() {
        guard let window else { return }
        let mouse = window.mouseLocationOutsideOfEventStream
        let point = convert(mouse, from: nil)
        pointer = bounds.contains(point) ? point : nil
        updateHover()
        chrome.needsDisplay = true
    }

    func needsDisplayChrome() { chrome.needsDisplay = true }

    private func updateHover() {
        guard dragOrigin == nil, let pointer else { hover = nil; return }
        let target = ScreenGeometry.window(at: pointer, in: windows)
        if target?.id != hover?.id {
            hover = target
            if let target { startHighlight(to: target.frame) }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        refreshPointer()
    }

    override func mouseEntered(with event: NSEvent) { refreshPointer() }
    override func mouseExited(with event: NSEvent) { pointer = nil; hover = nil; chrome.needsDisplay = true }

    override func scrollWheel(with event: NSEvent) {
        guard controller?.loupeOn == true else { return }
        // 連続した（トラックパッドの）ホイールは、まとめて 1 段：一定以上たまったら、1 段進める
        let delta = event.scrollingDeltaY
        guard abs(delta) > (event.hasPreciseScrollingDeltas ? 4 : 0.5) else { return }
        controller?.adjustZoom(by: delta)
    }

    // MARK: ドラッグ

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        lastDrag = point
        selection = .zero
        hover = nil
        pointer = point
        chrome.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        if controller?.spaceDown == true, selection.width > 0 {
            // Space：大きさを変えず、範囲を動かす
            let delta = CGPoint(x: point.x - lastDrag.x, y: point.y - lastDrag.y)
            selection.origin.x += delta.x
            selection.origin.y += delta.y
            dragOrigin = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
        } else {
            selection = ScreenGeometry.selectionRect(from: origin, to: point, square: event.modifierFlags.contains(.shift), fromCenter: event.modifierFlags.contains(.option))
        }
        selection = ScreenGeometry.clamp(selection, to: bounds)
        lastDrag = point
        chrome.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let origin = dragOrigin else { return }
        dragOrigin = nil
        if ScreenGeometry.isClick(from: origin, to: point) {
            selection = .zero
            if let window = ScreenGeometry.window(at: point, in: windows) { controller?.confirmWindow(window, in: self) }
            refreshPointer()
            return
        }
        guard selection.width >= ScreenGeometry.minimumSelection, selection.height >= ScreenGeometry.minimumSelection else {
            selection = .zero
            refreshPointer()
            return
        }
        controller?.confirmRegion(selection, in: self)
    }

    override func keyDown(with event: NSEvent) {
        // 押したキーは、ローカルのモニターが先に受ける。ここへ来るのは、受けなかったキー（ビープ音を出さない）
    }

    // MARK: 光る枠（なめらかに動く）

    private func startHighlight(to target: CGRect) {
        if highlight == .zero { highlight = target }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepHighlight() }
        }
    }

    private func stepHighlight() {
        guard let target = hover?.frame else { stopTimer(); return }
        let ease: CGFloat = 0.32
        highlight = CGRect(x: highlight.minX + (target.minX - highlight.minX) * ease, y: highlight.minY + (target.minY - highlight.minY) * ease,
                           width: highlight.width + (target.width - highlight.width) * ease, height: highlight.height + (target.height - highlight.height) * ease)
        if abs(highlight.minX - target.minX) + abs(highlight.minY - target.minY) + abs(highlight.width - target.width) + abs(highlight.height - target.height) < 0.5 {
            highlight = target
            stopTimer()
        }
        chrome.needsDisplay = true
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// 撮った瞬間の、白い光（範囲が、一瞬、光る）。終わったら `done`。
    func flash(_ rect: CGRect, done: @escaping @MainActor () -> Void) {
        stopTimer()
        selection = rect
        flashRect = rect
        flashAlpha = 0.65
        chrome.needsDisplay = true
        let started = Date()
        let duration = 0.16
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, Date().timeIntervalSince(started) / duration)
                self.flashAlpha = 0.65 * (1 - CGFloat(progress))
                self.chrome.needsDisplay = true
                if progress >= 1 { timer.invalidate(); self.timer = nil; done() }
            }
        }
    }

    // MARK: 拡大鏡

    /// ポインタの下のピクセルの色（`#RRGGBB`）。
    func colorHexUnderPointer() -> String? {
        guard let pointer else { return nil }
        return pixel(at: CGPoint(x: (pointer.x * scale).rounded(.down), y: (pointer.y * scale).rounded(.down))).map { ScreenGeometry.hex(red: $0.0, green: $0.1, blue: $0.2) }
    }

    func copyColorUnderPointer() {
        guard controller?.loupeOn == true, let hex = colorHexUnderPointer() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        chrome.toast("\(hex) をコピーしました")
    }

    /// 画像のピクセル座標（左上が原点）の色。
    func pixel(at p: CGPoint) -> (UInt8, UInt8, UInt8)? {
        guard p.x >= 0, p.y >= 0, Int(p.x) < image.width, Int(p.y) < image.height, let one = image.cropping(to: CGRect(x: Int(p.x), y: Int(p.y), width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? (data[0], data[1], data[2]) : nil
    }

    // MARK: 描画に渡す状態

    struct Snapshot {
        let selection: CGRect
        let hover: ScreenGeometry.PickableWindow?
        let highlight: CGRect
        let pointer: CGPoint?
        let flashRect: CGRect?
        let flashAlpha: CGFloat
        let dragging: Bool
    }

    var snapshot: Snapshot { Snapshot(selection: selection, hover: hover, highlight: highlight, pointer: pointer, flashRect: flashRect, flashAlpha: flashAlpha, dragging: dragOrigin != nil) }
}

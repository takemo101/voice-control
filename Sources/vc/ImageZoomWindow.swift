import AppKit
import Foundation
import SwiftUI

/// 拡大の窓：図（Mermaid）・Markdown の画像を、**縮めずに**出す。見た目は、Markdown のウィンドウと同じ、**Liquid Glass のカード**（見出し・本文・下のボタン）。
/// - **拡大縮小**：ピンチ・ダブルクリック（クリックした所へ）・⌘（または ⌥）＋スクロール（カーソルの所を、動かさずに）・「＋」「−」ボタン（`+` `-` キー）。倍率は、見出しの下の行に、いつも出る。
/// - **動かす**：つかんでドラッグ・2 本指のスワイプ・矢印キー。
/// - **コピー**：「画像をコピー」（⌘C。スクリーンショットの窓と同じ）。クリップボードへ入れるだけ（ファイルは作らない）。
/// - **戻す**：「元に戻す」（`0`。全体が見える大きさ・中央）・「等倍」（`1`。100%）。ウィンドウの大きさを変えても、全体表示のままなら、全体表示を保つ。
/// - Esc・⌘W で閉じる。倍率の計算は `ZoomMath`（純粋）。
@MainActor final class ImageZoomWindow: NSObject, NSWindowDelegate {
    private static var open: [ImageZoomWindow] = []
    private static let margin: CGFloat = 20          // 全体表示のとき、画像のまわりに残す余白
    private static let chromeHeight: CGFloat = 118   // 見出し・下の行・仕切りの高さ（最初の窓の大きさを決めるための目安。実際の領域は、表示後に測り直す）
    private static let minContent = NSSize(width: 660, height: 360)

    private let window: ZoomWindow
    private let scroll = ZoomScrollView()
    private let imageView = ZoomImageView()
    private let state = ZoomState()
    private let image: NSImage
    private let imageSize: CGSize
    private var animation: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastFit: CGFloat = 1

    /// 図を、拡大の窓で見せる（描けなければ、何もしない）。
    static func show(source: String) {
        guard let image = MermaidImage.zoomImage(for: source) else { return }
        show(image: image, title: "図", symbol: "point.3.connected.trianglepath.dotted")
    }

    /// 画像を、拡大の窓で見せる。
    static func show(image: NSImage, title: String, symbol: String = "photo") {
        let controller = ImageZoomWindow(image: image, title: title, symbol: symbol)
        open.append(controller)
        controller.present()
    }

    private init(image: NSImage, title: String, symbol: String) {
        self.image = image
        imageSize = image.size
        let area = ScreenPlacement.currentVisibleFrame().size
        let viewport = CGSize(width: area.width * 0.85, height: area.height * 0.85 - Self.chromeHeight)
        let fit0 = ZoomMath.fit(image: image.size, viewport: viewport, margin: Self.margin)
        let content = NSSize(width: max(Self.minContent.width, image.size.width * fit0 + 2 * Self.margin),
                             height: max(Self.minContent.height, image.size.height * fit0 + 2 * Self.margin + Self.chromeHeight))
        window = ZoomWindow(contentRect: NSRect(origin: .zero, size: content), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        // 会話のウィンドウ・Markdown のウィンドウ（`.statusBar` の 1 つ上）より、さらに上（上のパネル〔HUD〕は、+2）
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        window.isMovableByWindowBackground = true
        window.minSize = Self.minContent
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onCommand = { [unowned self] in perform($0) }

        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        imageView.imageScaling = .scaleNone
        imageView.onDoubleClick = { [unowned self] point in doubleClick(at: point) }
        imageView.onDrag = { [unowned self] dx, dy in pan(dx: dx, dy: dy, inScreenPoints: true) }
        let clip = CenteringClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scroll.contentView = clip
        scroll.documentView = imageView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.allowsMagnification = true
        scroll.minMagnification = ZoomMath.minimum
        scroll.maxMagnification = ZoomMath.maximum
        scroll.postsFrameChangedNotifications = true
        scroll.onModifiedScroll = { [unowned self] delta, location in magnify(by: delta, pinnedAt: location) }

        let root = ZoomView(
            title: title, symbol: symbol, state: state, scroll: scroll,
            zoomIn: { [unowned self] in perform(.zoomIn) }, zoomOut: { [unowned self] in perform(.zoomOut) },
            reset: { [unowned self] in perform(.reset) }, actual: { [unowned self] in perform(.actual) }, copy: { [unowned self] in perform(.copy) },
            close: { [unowned self] in window.close() })
        window.contentView = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        window.setFrame(ScreenPlacement.windowFrame(size: window.frame.size, minSize: window.minSize, in: ScreenPlacement.currentVisibleFrame()), display: false)

        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshState() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportChanged() }
        })
    }

    private func present() {
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 本物の領域（見出し・下の行を除いた）を測って、全体表示にする
        window.contentView?.layoutSubtreeIfNeeded()
        applyFit(animated: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            window.animator().alphaValue = 1
        }
    }

    // MARK: 倍率

    /// いまの領域に、全体が入る倍率。
    private var fit: CGFloat { ZoomMath.fit(image: imageSize, viewport: scroll.contentSize, margin: Self.margin) }

    private func perform(_ command: ZoomCommand) {
        switch command {
        case .zoomIn: animate(to: ZoomMath.step(from: scroll.magnification, direction: 1), centeredAt: visibleCenter)
        case .zoomOut: animate(to: ZoomMath.step(from: scroll.magnification, direction: -1), centeredAt: visibleCenter)
        case .reset: applyFit(animated: true)
        case .actual: animate(to: 1, centeredAt: visibleCenter)
        case .pan(let dx, let dy): pan(dx: dx, dy: dy, inScreenPoints: true)
        case .copy: copyImage()
        }
    }

    /// 画像を、クリップボードへ（PNG と TIFF。ファイルは、作らない）。押したあと、少しの間、ボタンを「コピーしました」にする。
    private func copyImage() {
        let item = NSPasteboardItem()
        guard let tiff = image.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
        if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([item]) else { return }
        state.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.state.copied = false }
    }

    /// 全体が見える大きさ・中央へ（「元に戻す」）。
    private func applyFit(animated: Bool) {
        let target = fit
        scroll.minMagnification = min(ZoomMath.minimum, target)
        lastFit = target
        let center = NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        if animated { animate(to: target, centeredAt: center) } else { stopAnimation(); scroll.setMagnification(target, centeredAt: center); refreshState() }
    }

    private func doubleClick(at point: NSPoint) {
        let target = ZoomMath.doubleClickTarget(current: scroll.magnification, fit: fit)
        animate(to: target, centeredAt: abs(target - fit) < 0.001 ? NSPoint(x: imageSize.width / 2, y: imageSize.height / 2) : point)
    }

    /// いま見えている範囲の、真ん中（画像の座標）。
    private var visibleCenter: NSPoint { let rect = scroll.documentVisibleRect; return NSPoint(x: rect.midX, y: rect.midY) }

    private func animate(to target: CGFloat, centeredAt center: NSPoint) {
        stopAnimation()
        let goal = ZoomMath.clamp(target, lowerBound: scroll.minMagnification)
        let start = scroll.magnification
        guard abs(goal - start) > 0.0005 else { return }
        let began = Date()
        let duration = 0.16
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(began) / duration)
                let eased = 1 - pow(1 - t, 3)
                self.scroll.setMagnification(start + (goal - start) * eased, centeredAt: center)
                if t >= 1 { self.stopAnimation() }
            }
        }
    }

    private func stopAnimation() { animation?.invalidate(); animation = nil }

    /// ⌘（または ⌥）＋スクロール：カーソルの下の点を、動かさずに、拡大縮小する。
    private func magnify(by delta: CGFloat, pinnedAt location: NSPoint) {
        stopAnimation()
        let before = imageView.convert(location, from: nil)
        scroll.magnification = ZoomMath.clamp(scroll.magnification * exp(delta), lowerBound: scroll.minMagnification)
        let after = imageView.convert(location, from: nil)
        scrollOrigin(by: NSPoint(x: before.x - after.x, y: before.y - after.y))
    }

    /// 動かす（`inScreenPoints`：画面の点。いまの倍率で、画像の座標へ直す）。ドラッグは、つかんだ向き（内容が、マウスについてくる）。
    private func pan(dx: CGFloat, dy: CGFloat, inScreenPoints: Bool) {
        let factor = inScreenPoints ? 1 / max(0.01, scroll.magnification) : 1
        scrollOrigin(by: NSPoint(x: dx * factor, y: dy * factor))
    }

    private func scrollOrigin(by delta: NSPoint) {
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: origin.x + delta.x, y: origin.y + delta.y), size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: 状態（画面に出す）

    private func refreshState() {
        let magnification = scroll.magnification
        state.magnification = magnification
        state.canZoomIn = magnification < ZoomMath.maximum - 0.001
        state.canZoomOut = magnification > scroll.minMagnification + 0.001
        state.isFitted = abs(magnification - fit) < 0.01
        state.isActual = abs(magnification - 1) < 0.005
    }

    /// ウィンドウの大きさが変わった：全体表示のままだったなら、新しい大きさでも、全体表示を保つ。
    private func viewportChanged() {
        let wasFitted = abs(scroll.magnification - lastFit) < 0.01
        let target = fit
        lastFit = target
        if wasFitted { scroll.minMagnification = min(ZoomMath.minimum, target); scroll.setMagnification(target, centeredAt: NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)) }
        refreshState()
    }

    func windowWillClose(_ notification: Notification) {
        stopAnimation()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        Self.open.removeAll { $0 === self }
    }
}

// MARK: 操作とキー

enum ZoomCommand { case zoomIn, zoomOut, reset, actual, copy, pan(dx: CGFloat, dy: CGFloat) }

/// 枠のないウィンドウ：キーを受けられる。`+` `-` `0` `1`（⌘つきも）・矢印・Esc・⌘C（画像をコピー）・⌘W。
private final class ZoomWindow: NSWindow {
    var onCommand: ((ZoomCommand) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift) == .command, let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        if key == "w" { close(); return true }
        if key == "c" { onCommand?(.copy); return true }
        if let command = Self.command(for: key) { onCommand?(command); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }
        let step: CGFloat = 80
        switch event.keyCode {
        case 123: onCommand?(.pan(dx: -step, dy: 0)); return
        case 124: onCommand?(.pan(dx: step, dy: 0)); return
        case 125: onCommand?(.pan(dx: 0, dy: -step)); return
        case 126: onCommand?(.pan(dx: 0, dy: step)); return
        default: break
        }
        if let key = event.charactersIgnoringModifiers, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift).isEmpty, let command = Self.command(for: key) { onCommand?(command); return }
        super.keyDown(with: event)
    }

    private static func command(for key: String) -> ZoomCommand? {
        switch key {
        case "+", "=": return .zoomIn
        case "-", "_": return .zoomOut
        case "0": return .reset
        case "1": return .actual
        default: return nil
        }
    }
}

/// ⌘（または ⌥）つきのスクロールを、拡大縮小に回すスクロールビュー（ふつうのスクロールは、動かす）。
private final class ZoomScrollView: NSScrollView {
    var onModifiedScroll: ((CGFloat, NSPoint) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) else { super.scrollWheel(with: event); return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)
        if delta != 0 { onModifiedScroll?(delta, event.locationInWindow) }
    }
}

/// ダブルクリック（クリックした点を、画像の座標で渡す）・ドラッグ（つかんで動かす：開いた手・つかんだ手）を受ける画像。
private final class ZoomImageView: NSImageView {
    var onDoubleClick: ((NSPoint) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .openHand) }

    private var last = NSPoint.zero

    override func mouseDown(with event: NSEvent) {
        last = event.locationInWindow
        if event.clickCount == 2 { onDoubleClick?(convert(event.locationInWindow, from: nil)) } else { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        // 内容が、マウスについてくる：右へ動かすと、見える範囲は、左へ。上へ動かすと、見える範囲は、下へ（座標は、下が原点）。動いた量は、ウィンドウの位置の差で測る（`deltaX` は、合成した入力では、0）
        let location = event.locationInWindow
        onDrag?(last.x - location.x, last.y - location.y)
        last = location
    }

    override func mouseUp(with event: NSEvent) { if event.clickCount < 2 { NSCursor.pop() } }
}

/// 小さい図を、中央に置くクリップビュー（標準は、左上に寄る）。
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

// MARK: SwiftUI の枠（Markdown のウィンドウと同じ、ガラスのカード）

/// 画面の状態。SwiftUI の `@State` は、この環境では使えないので、`ObservableObject`。
@MainActor final class ZoomState: ObservableObject {
    @Published var magnification: CGFloat = 1
    @Published var canZoomIn = true
    @Published var canZoomOut = true
    @Published var isFitted = true   // 全体表示（「元に戻す」は、押しても変わらない）
    @Published var isActual = false  // 等倍
    @Published var copied = false    // 「コピーしました」を、出している間
}

private struct ZoomView: View {
    let title: String
    let symbol: String
    @ObservedObject var state: ZoomState
    let scroll: NSScrollView
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let reset: () -> Void
    let actual: () -> Void
    let copy: () -> Void
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 0) {
            header
            Rule()
            ZoomBody(scroll: scroll)
            Rule()
            footer
        }
        .glassEffect(.regular.tint(DocumentPalette.accent.opacity(0.06)), in: shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.05), DocumentPalette.accent.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .clipShape(shape)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(DocumentPalette.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(DocumentPalette.accent)
            }
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 8)
            Text("ピンチ・ダブルクリック・ドラッグ").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(.white.opacity(0.1)))
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.45))
            }.buttonStyle(.plain).accessibilityLabel("閉じる")
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(DragArea())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            RoundStepButton(symbol: "minus", help: "縮小（−）", enabled: state.canZoomOut, action: zoomOut)
            Text(ZoomMath.percent(state.magnification))
                .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.92))
                .frame(minWidth: 46)
            RoundStepButton(symbol: "plus", help: "拡大（＋）", enabled: state.canZoomIn, action: zoomIn)
            PillButton(title: "元に戻す  0", symbol: "arrow.counterclockwise", flashed: false, action: reset)
                .disabled(state.isFitted).opacity(state.isFitted ? 0.4 : 1).help("全体が見える大きさ・中央へ")
            PillButton(title: "等倍  1", symbol: "1.magnifyingglass", flashed: false, action: actual)
                .disabled(state.isActual).opacity(state.isActual ? 0.4 : 1).help("100%（元の大きさ）")
            Spacer(minLength: 8)
            PrimaryPill(title: "画像をコピー", symbol: "photo.on.rectangle", key: "⌘C", flashed: state.copied, action: copy)
            PillButton(title: "閉じる  esc", symbol: "xmark", flashed: false, cancel: true, action: close)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(DragArea())
    }
}

/// 丸い小さなボタン（＋・−）。
private struct RoundStepButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.92))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(hover.on && enabled ? 0.22 : 0.12)))
                .overlay(Circle().strokeBorder(.white.opacity(hover.on && enabled ? 0.28 : 0.16), lineWidth: 0.7))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .onHover { hover.on = $0 }
        .help(help)
    }
}

/// 本文（拡大縮小できるスクロールビューを、そのまま入れる）。
private struct ZoomBody: NSViewRepresentable {
    let scroll: NSScrollView
    func makeNSView(context: Context) -> NSScrollView { scroll }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

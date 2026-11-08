import AppKit
import CoreGraphics
import SwiftUI

/// 範囲を選んで撮る画面（ショートカット・`vc shot`）。**撮り始める前の静止画**（`ScreenGrab`）を、ディスプレイごとの全面のパネルに暗くして見せ、そこから選ぶ。
/// 操作：
/// - ドラッグ：範囲。**⇧** 正方形・**⌥** 始点が中心・**Space を押しながら** 動かす
/// - 範囲の大きさを、ピクセルで（「1000 × 300」）出す
/// - ウィンドウの上に置くと、枠が光り、**クリック**で、そのウィンドウ
/// - **↩** 全画面（マウスのあるディスプレイ）・**R** 前回の範囲・**Esc** 取りやめ
/// - **Z** 拡大鏡（ホイールで倍率・**C** で、ピクセルの色〔#RRGGBB〕をコピー・矢印で、ポインタを 1 ピクセル〔⇧ で 10〕）
/// 結果の画像は、静止画から切り抜く（ピクセルのまま）。メインアクターで動く。
@MainActor final class ScreenSelector {
    struct Capture {
        let image: CGImage
        let region: LastRegion
    }

    enum Outcome {
        case captured(Capture)
        case cancelled
        case failed(String)
    }

    /// 前回の範囲（R）：ディスプレイと、そのビューの枠。プロセスの中だけ（ファイルに残さない）。
    struct LastRegion: Equatable {
        let displayID: CGDirectDisplayID
        let rect: CGRect
    }

    static var lastRegion: LastRegion?
    private static var active: ScreenSelector?

    // MARK: 入口

    /// 選ぶ。選び終わる（撮った・取りやめ）まで待つ。**イベントのループ（`NSApplication.run()`）が回っているとき**に呼ぶ（`vc listen --hotkey`。単独のコマンドは、`runStandalone`）。
    static func select() async -> Outcome {
        guard active == nil else { return .cancelled }   // 選んでいる最中の、2 回目
        let frames: [ScreenGrab.Frame]
        do { frames = try await ScreenGrab.frames() } catch { return .failed("\(error)") }
        return await withCheckedContinuation { continuation in
            let selector = ScreenSelector(frames: frames) { continuation.resume(returning: $0) }
            active = selector
            selector.begin()
        }
    }

    /// 単独のコマンド（`vc shot`）：イベントのループを回して、`work` を実行し、終わったら、ループを止める。
    static func runStandalone<T>(_ work: @escaping @MainActor () async -> T) -> T {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var result: T?
        Task { @MainActor in
            result = await work()
            app.stop(nil)
            // `stop` は、次のイベントを処理したあとで、ループを抜ける。空のイベントを送って、起こす
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(wake, atStart: true)
            }
        }
        app.run()
        return result!
    }

    // MARK: 状態

    private let frames: [ScreenGrab.Frame]
    private var completion: ((Outcome) -> Void)?
    private var panels: [SelectorPanel] = []
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private(set) var loupeOn = false
    private(set) var loupeZoom = ScreenGeometry.defaultZoom
    private(set) var spaceDown = false
    private let guide = GuideState()
    private var finishing = false

    private init(frames: [ScreenGrab.Frame], completion: @escaping (Outcome) -> Void) {
        self.frames = frames
        self.completion = completion
    }

    private func begin() {
        previousApp = NSWorkspace.shared.frontmostApplication
        let windows = ScreenGrab.windows()
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let frame = frames.first(where: { $0.displayID == id }) else { continue }
            let pickable = windows.map {
                ScreenGeometry.PickableWindow(id: $0.id, frame: ScreenGeometry.viewRect(fromWindowServer: $0.bounds, mainScreenHeight: mainHeight, screenFrame: screen.frame), title: $0.title)
            }.filter { $0.frame.intersects(CGRect(origin: .zero, size: screen.frame.size)) }
            let panel = SelectorPanel(screen: screen)
            let view = SelectorView(controller: self, displayID: id, image: frame.image, windows: pickable, visibleBottom: screen.frame.maxY - screen.visibleFrame.minY, guide: guide)
            view.frame = CGRect(origin: .zero, size: screen.frame.size)
            panel.contentView = view
            panels.append(panel)
        }
        guard !panels.isEmpty else { finish(.failed("画面が見つかりません")); return }
        installMonitors()
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for panel in panels {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
        let first = panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels[0]
        first.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
        panels.forEach { $0.selectorView.refreshPointer() }
    }

    // MARK: キー

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window is SelectorPanel else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
        // 別のアプリがキーを受けているとき（パネルが、キーのウィンドウでないとき）の Esc
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        }
    }

    /// 受けたキーなら true（イベントを、ほかへ渡さない）。
    private func handleKey(_ event: NSEvent) -> Bool {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if event.type == .keyUp {
            guard event.keyCode == 49, spaceDown else { return false }
            spaceDown = false
            return true
        }
        switch event.keyCode {
        case 53: finish(.cancelled)
        case 36, 76: captureFullScreenUnderMouse()   // Return・テンキーの Enter
        case 49:   // Space：ドラッグの途中なら、範囲を動かす
            guard panels.contains(where: { $0.selectorView.isDragging }) else { return false }
            spaceDown = true
        case 6 where plain: toggleLoupe()   // Z
        case 8 where plain: panelUnderMouse()?.selectorView.copyColorUnderPointer()   // C
        case 15 where plain: repeatLastRegion()   // R
        case 123, 124, 125, 126:   // 矢印：拡大鏡が出ているときだけ（`where` は、最後の 1 つにしか効かないので、中で確かめる）
            guard plain, loupeOn else { return false }
            nudgePointer(keyCode: event.keyCode, fast: event.modifierFlags.contains(.shift))
        default: return false
        }
        return true
    }

    private func panelUnderMouse() -> SelectorPanel? {
        let mouse = NSEvent.mouseLocation
        return panels.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    private func toggleLoupe() {
        loupeOn.toggle()
        guide.loupe = loupeOn
        panels.forEach { $0.selectorView.refreshPointer() }
    }

    func adjustZoom(by delta: CGFloat) {
        loupeZoom = ScreenGeometry.zoom(loupeZoom, scrollDelta: delta)
        panels.forEach { $0.selectorView.needsDisplayChrome() }
    }

    /// 矢印：ポインタを、1 ピクセル（⇧ で 10）動かす（拡大鏡で、ピクセル単位で選ぶ）。
    private func nudgePointer(keyCode: UInt16, fast: Bool) {
        guard let panel = panelUnderMouse(), !panel.selectorView.isDragging else { return }
        let step = (fast ? 10 : 1) / panel.backingScaleFactor
        var dx: CGFloat = 0, dy: CGFloat = 0   // Cocoa の向き：上が +
        switch keyCode {
        case 123: dx = -step
        case 124: dx = step
        case 126: dy = step
        default: dy = -step
        }
        let mouse = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        // ポインタの移動は、全画面の座標（原点は、主ディスプレイの左上）
        CGWarpMouseCursorPosition(CGPoint(x: mouse.x + dx, y: height - (mouse.y + dy)))
        panels.forEach { $0.selectorView.refreshPointer() }
    }

    // MARK: 撮る

    func confirmRegion(_ rect: CGRect, in view: SelectorView) {
        capture(rect, in: view)
    }

    func confirmWindow(_ window: ScreenGeometry.PickableWindow, in view: SelectorView) {
        capture(ScreenGeometry.clamp(window.frame, to: view.bounds), in: view)
    }

    private func captureFullScreenUnderMouse() {
        guard let view = panelUnderMouse()?.selectorView else { return }
        capture(view.bounds, in: view)
    }

    private func repeatLastRegion() {
        guard let last = Self.lastRegion, let view = panels.map(\.selectorView).first(where: { $0.displayID == last.displayID }) else { return }
        capture(ScreenGeometry.clamp(last.rect, to: view.bounds), in: view)
    }

    private func capture(_ rect: CGRect, in view: SelectorView) {
        guard !finishing, rect.width >= ScreenGeometry.minimumSelection, rect.height >= ScreenGeometry.minimumSelection else { return }
        let crop = ScreenGeometry.cropRect(selection: rect, viewSize: view.bounds.size, imageSize: CGSize(width: view.image.width, height: view.image.height))
        guard let cropped = view.image.cropping(to: crop) else { finish(.failed("画像を切り抜けません")); return }
        let region = LastRegion(displayID: view.displayID, rect: rect)
        Self.lastRegion = region
        finishing = true
        view.flash(rect) { [weak self] in self?.finish(.captured(Capture(image: cropped, region: region))) }
    }

    // MARK: 終わる

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        keyMonitor = nil; globalKeyMonitor = nil
        let closing = panels
        panels = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            // 消え終わるまで、`self` を手放さない（描画が、まだ、状態を読む）
            MainActor.assumeIsolated { closing.forEach { $0.orderOut(nil) }; withExtendedLifetime(self) {} }
        })
        // 撮る前に前面だったアプリへ、戻す（声で入力するときの、貼り付け先）
        if let previous = previousApp, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous.activate() }
        Self.active = nil
        completion(outcome)
    }

}

import AppKit
import SwiftUI

/// 選択の面の上に重ねる、暗い覆い・枠・大きさの表示・拡大鏡・案内。**下の静止画は、ここで描き直さない**（覆いに、選んだ所だけ穴をあける）。
@MainActor final class ChromeView: NSView {
    weak var owner: SelectorView?
    private let guide: GuideState
    private let visibleBottom: CGFloat
    private let guideHost: NSHostingView<GuideBar>
    private var toastText: String?
    private var toastTimer: Timer?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // マウスは、下の `SelectorView` が受ける

    private enum Style {
        static let dim = NSColor(srgbRed: 0.03, green: 0.04, blue: 0.09, alpha: 0.52)
        static let accent = NSColor(srgbRed: 0.40, green: 0.82, blue: 1.0, alpha: 1)
        static let violet = NSColor(srgbRed: 0.62, green: 0.52, blue: 1.0, alpha: 1)
    }

    init(guide: GuideState, visibleBottom: CGFloat) {
        self.guide = guide
        self.visibleBottom = visibleBottom
        guideHost = PassThroughHost(rootView: GuideBar(state: guide))
        super.init(frame: .zero)
        addSubview(guideHost)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override func layout() {
        super.layout()
        let size = guideHost.fittingSize
        guideHost.frame = CGRect(x: (bounds.width - size.width) / 2, y: max(8, visibleBottom - 22 - size.height), width: size.width, height: size.height)
    }

    func toast(_ text: String) {
        toastText = text
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.toastText = nil; self?.needsDisplay = true }
        }
        needsDisplay = true
    }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let owner else { return }
        let state = owner.snapshot
        let dragging = state.dragging && state.selection.width > 0 && state.selection.height > 0
        // 穴：撮る瞬間・ドラッグ中の範囲・ウィンドウの上に置いたときの、そのウィンドウ
        var cut: CGRect?
        var radius: CGFloat = 4
        if let flash = state.flashRect { cut = flash }
        else if dragging { cut = state.selection }
        else if state.hover != nil { cut = state.highlight; radius = 12 }

        context.setFillColor(Style.dim.cgColor)
        if let cut {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRoundedRect(in: cut, cornerWidth: min(radius, cut.width / 2), cornerHeight: min(radius, cut.height / 2))
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        } else {
            context.fill(bounds)
        }

        if let pointer = state.pointer, cut == nil { drawCrosshair(context, at: pointer) }

        if let cut {
            if state.flashRect != nil {
                context.setFillColor(NSColor.white.withAlphaComponent(state.flashAlpha).cgColor)
                context.addPath(CGPath(roundedRect: cut, cornerWidth: min(radius, cut.width / 2), cornerHeight: min(radius, cut.height / 2), transform: nil))
                context.fillPath()
            }
            if state.flashRect == nil { dragging ? drawSelection(context, cut) : drawWindowHighlight(context, cut) }
            let (w, h) = ScreenGeometry.pixelSize(of: cut, scale: owner.scale)
            if state.flashRect == nil {
                if dragging { drawPill("\(w) × \(h)", secondary: ScreenGeometry.aspectLabel(width: w, height: h), above: cut) }
                else if let hover = state.hover { drawPill("\(w) × \(h)", secondary: hover.title.isEmpty ? nil : hover.title, above: cut) }
            }
        }
        if let pointer = state.pointer, owner.controller?.loupeOn == true, state.flashRect == nil { drawLoupe(context, at: pointer, owner: owner) }
        if let toastText { drawToast(toastText) }
    }

    /// ポインタを通る、細い線（ドラッグを始める前の、位置合わせ）。
    private func drawCrosshair(_ context: CGContext, at p: CGPoint) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.move(to: CGPoint(x: 0, y: p.y.rounded() + 0.5)); context.addLine(to: CGPoint(x: bounds.width, y: p.y.rounded() + 0.5))
        context.move(to: CGPoint(x: p.x.rounded() + 0.5, y: 0)); context.addLine(to: CGPoint(x: p.x.rounded() + 0.5, y: bounds.height))
        context.strokePath()
        context.restoreGState()
    }

    /// ドラッグ中の範囲：光る縁・細い白線・四隅の留め金。
    private func drawSelection(_ context: CGContext, _ rect: CGRect) {
        let outer = CGPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 14, color: Style.accent.withAlphaComponent(0.65).cgColor)
        context.addPath(outer)
        context.setStrokeColor(Style.accent.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(2)
        context.strokePath()
        context.restoreGState()
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        // 四隅の留め金
        let length = min(16, rect.width / 3, rect.height / 3)
        guard length >= 6 else { return }
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setStrokeColor(NSColor.white.cgColor)
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            context.move(to: CGPoint(x: corner.x - dx * 1.5, y: corner.y + dy * length))
            context.addLine(to: CGPoint(x: corner.x - dx * 1.5, y: corner.y - dy * 1.5))
            context.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y - dy * 1.5))
        }
        context.strokePath()
    }

    /// ウィンドウの上に置いたときの、光る枠（色は、水色から紫へ）。
    private func drawWindowHighlight(_ context: CGContext, _ rect: CGRect) {
        let path = CGPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.25), cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.addPath(path)
        context.setFillColor(Style.accent.withAlphaComponent(0.09).cgColor)
        context.fillPath()
        context.saveGState()
        context.setShadow(offset: .zero, blur: 18, color: Style.accent.withAlphaComponent(0.55).cgColor)
        context.addPath(path)
        context.setStrokeColor(Style.accent.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(2.5)
        context.strokePath()
        context.restoreGState()
        // 縁の上に、斜めのグラデーション（水色 → 紫）
        context.saveGState()
        context.addPath(path)
        context.setLineWidth(2.5)
        context.replacePathWithStrokedPath()
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Style.accent.cgColor, Style.violet.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
        context.restoreGState()
    }

    // MARK: ことば（大きさの表示）

    /// ガラス風の丸い札。`rect` の上（入らなければ、中の上）に出す。主：「1000 × 300」。副：比・ウィンドウの名前。
    private func drawPill(_ primary: String, secondary: String?, above rect: CGRect) {
        let primaryAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.white]
        let secondaryAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.62)]
        let primarySize = primary.size(withAttributes: primaryAttrs)
        let shown = secondary.map { String($0.prefix(40)) }
        let secondarySize = shown?.size(withAttributes: secondaryAttrs) ?? .zero
        let gap: CGFloat = shown == nil ? 0 : 8
        let size = CGSize(width: primarySize.width + gap + secondarySize.width + 24, height: 26)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        if origin.y < 8 { origin.y = rect.minY + 10 }
        origin.x = max(8, min(origin.x, bounds.width - size.width - 8))
        origin.y = max(8, min(origin.y, bounds.height - size.height - 8))
        drawGlass(CGRect(origin: origin, size: size))
        primary.draw(at: CGPoint(x: origin.x + 12, y: origin.y + (size.height - primarySize.height) / 2), withAttributes: primaryAttrs)
        if let shown { shown.draw(at: CGPoint(x: origin.x + 12 + primarySize.width + gap, y: origin.y + (size.height - secondarySize.height) / 2), withAttributes: secondaryAttrs) }
    }

    private func drawGlass(_ rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.addPath(path)
        context.setFillColor(NSColor(srgbRed: 0.06, green: 0.07, blue: 0.12, alpha: 0.74).cgColor)
        context.fillPath()
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
        context.setLineWidth(0.8)
        context.strokePath()
    }

    private func drawToast(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let rect = CGRect(x: (bounds.width - size.width - 28) / 2, y: 44, width: size.width + 28, height: 30)
        drawGlass(rect)
        text.draw(at: CGPoint(x: rect.minX + 14, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attrs)
    }

    // MARK: 拡大鏡

    private func drawLoupe(_ context: CGContext, at p: CGPoint, owner: SelectorView) {
        let diameter: CGFloat = 148
        let zoom = owner.controller?.loupeZoom ?? ScreenGeometry.defaultZoom
        var center = CGPoint(x: p.x + 26 + diameter / 2, y: p.y + 26 + diameter / 2)
        if center.x + diameter / 2 + 12 > bounds.width { center.x = p.x - 26 - diameter / 2 }
        if center.y + diameter / 2 + 56 > bounds.height { center.y = p.y - 26 - diameter / 2 - 40 }
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)

        // 中心のピクセル（画像の座標）
        let px = (p.x * owner.scale).rounded(.down), py = (p.y * owner.scale).rounded(.down)
        let span = ceil(diameter / zoom) + 2
        let source = CGRect(x: px - (span / 2).rounded(.down), y: py - (span / 2).rounded(.down), width: span, height: span)
        let imageBounds = CGRect(x: 0, y: 0, width: owner.image.width, height: owner.image.height)
        let visible = source.intersection(imageBounds).integral

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 6), blur: 20, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.fillEllipse(in: circle)
        context.restoreGState()

        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        if !visible.isNull, let part = owner.image.cropping(to: visible) {
            context.interpolationQuality = .none
            // 中心のピクセルの真ん中が、円の中心に来る
            let dest = CGRect(x: center.x + (visible.minX - px - 0.5) * zoom, y: center.y + (visible.minY - py - 0.5) * zoom, width: visible.width * zoom, height: visible.height * zoom)
            context.translateBy(x: dest.minX, y: dest.maxY)
            context.scaleBy(x: 1, y: -1)   // ビューは、上が原点：画像は、上下を戻して描く
            context.draw(part, in: CGRect(x: 0, y: 0, width: dest.width, height: dest.height))
        }
        context.restoreGState()

        // 格子（ピクセルの境目）・中心のピクセル
        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        if zoom >= 8 {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
            context.setLineWidth(0.5)
            var x = center.x - zoom / 2 - ceil(diameter / zoom / 2) * zoom
            while x < circle.maxX { context.move(to: CGPoint(x: x, y: circle.minY)); context.addLine(to: CGPoint(x: x, y: circle.maxY)); x += zoom }
            var y = center.y - zoom / 2 - ceil(diameter / zoom / 2) * zoom
            while y < circle.maxY { context.move(to: CGPoint(x: circle.minX, y: y)); context.addLine(to: CGPoint(x: circle.maxX, y: y)); y += zoom }
            context.strokePath()
        }
        let cell = CGRect(x: center.x - zoom / 2, y: center.y - zoom / 2, width: zoom, height: zoom)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor); context.setLineWidth(2); context.stroke(cell.insetBy(dx: -1, dy: -1))
        context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(1.2); context.stroke(cell)
        context.restoreGState()

        // 縁：水色 → 紫
        context.saveGState()
        context.addEllipse(in: circle.insetBy(dx: 1, dy: 1))
        context.setLineWidth(2.5)
        context.replacePathWithStrokedPath()
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Style.accent.cgColor, Style.violet.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: circle.minX, y: circle.minY), end: CGPoint(x: circle.maxX, y: circle.maxY), options: [])
        }
        context.restoreGState()

        // 色と座標
        let color = owner.pixel(at: CGPoint(x: px, y: py))
        let hex = color.map { ScreenGeometry.hex(red: $0.0, green: $0.1, blue: $0.2) } ?? "—"
        let label = "\(hex)   \(Int(px)), \(Int(py))"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white]
        let textSize = label.size(withAttributes: attrs)
        let pill = CGRect(x: center.x - (textSize.width + 44) / 2, y: circle.maxY + 10, width: textSize.width + 44, height: 26)
        drawGlass(pill)
        if let color {
            let swatch = CGRect(x: pill.minX + 10, y: pill.midY - 6, width: 12, height: 12)
            NSColor(srgbRed: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1).setFill()
            let swatchPath = NSBezierPath(ovalIn: swatch)
            swatchPath.fill()
            NSColor.white.withAlphaComponent(0.7).setStroke()
            swatchPath.lineWidth = 1
            swatchPath.stroke()
        }
        label.draw(at: CGPoint(x: pill.minX + 30, y: pill.minY + (pill.height - textSize.height) / 2), withAttributes: attrs)
    }
}

// MARK: - 案内（下の中央）

/// 操作の案内：ガラスのカプセル。マウスは、素通し（下の面が受ける）。
private final class PassThroughHost: NSHostingView<GuideBar> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct GuideBar: View {
    @ObservedObject var state: GuideState

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "viewfinder").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(red: 0.40, green: 0.82, blue: 1.0))
                Text("範囲をドラッグ・ウィンドウをクリック").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 16)
            HStack(spacing: 10) {
                Key(key: "⇧", label: "正方形")
                Key(key: "⌥", label: "中心から")
                Key(key: "Space", label: "動かす")
                Key(key: "↩", label: "全画面")
                Key(key: "R", label: "前回")
                Key(key: "Z", label: state.loupe ? "拡大鏡 ON" : "拡大鏡", on: state.loupe)
                if state.loupe { Key(key: "C", label: "色をコピー") }
                Key(key: "esc", label: "やめる")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .glassEffect(.regular.tint(Color(red: 0.40, green: 0.82, blue: 1.0).opacity(0.06)), in: Capsule())
        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.05), Color(red: 0.40, green: 0.82, blue: 1.0).opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private struct Key: View {
        let key: String
        let label: String
        var on = false

        var body: some View {
            HStack(spacing: 5) {
                Text(key).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(on ? .black : .white.opacity(0.95))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Color(red: 0.40, green: 0.82, blue: 1.0) : .white.opacity(0.16)))
                Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.72))
            }
        }
    }
}

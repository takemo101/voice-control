import AppKit

// 画面の上のパネル（`HUD`）の、動く部品：波形・脈打つ点・考え中のドット・光る縁・経過時間。
// どれも、メインスレッドで動かし（`@MainActor`）、画面から外れたら、止まる（`viewDidMoveToWindow`）。音声そのものは、扱わない（音量の 0〜1 だけ）。

/// 録音中の波形：右が、いまの音量。左へ流れる。静かなときも、わずかに息づく（動いていないように見えないため）。
@MainActor final class WaveformView: NSView {
    private let barCount = 30
    private var bars: [CALayer] = []
    private var history: [Float]
    private var peak: Float = 0
    private var wave = 0.0
    private var timer: Timer?
    private let tint: NSColor

    init(tint: NSColor) {
        self.tint = tint
        history = [Float](repeating: 0, count: barCount)
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.cornerRadius = 1.5
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 音量（0〜1）を受け取る。次の描画までの最大を、使う。
    func push(_ level: Float) { peak = max(peak, level) }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func layout() {
        super.layout()
        draw(bars: history)
    }

    private func tick() {
        wave += 0.14
        let idle = 0.07 + 0.035 * Float(sin(wave))
        let target = max(peak, idle)
        peak *= 0.5
        let smoothed = (history.last ?? 0) * 0.4 + target * 0.6
        history.removeFirst()
        history.append(smoothed)
        draw(bars: history)
    }

    private func draw(bars values: [Float]) {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let barWidth: CGFloat = 3
        let gap = max(1, (w - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let v = CGFloat(values[i])
            let barHeight = max(3, v * h * 0.95)
            bar.frame = CGRect(x: CGFloat(i) * (barWidth + gap), y: (h - barHeight) / 2, width: barWidth, height: barHeight)
            // 古い（左の）ほど薄く、音量が大きいほど濃い
            let age = CGFloat(i) / CGFloat(barCount - 1)
            bar.backgroundColor = tint.withAlphaComponent(0.25 + 0.75 * min(1, 0.35 + v) * (0.35 + 0.65 * age)).cgColor
        }
        CATransaction.commit()
    }
}

/// 脈打つ点（録音中）：中心の点と、広がって消える輪。
@MainActor final class PulseDotView: NSView {
    private let tint: NSColor
    private let core = CALayer()
    private let ring = CALayer()

    init(tint: NSColor, size: CGFloat = 10) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size * 2.4).isActive = true
        heightAnchor.constraint(equalToConstant: size * 2.4).isActive = true
        core.backgroundColor = tint.cgColor
        core.cornerRadius = size / 2
        core.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ring.borderColor = tint.cgColor
        ring.borderWidth = 1.5
        ring.cornerRadius = size / 2
        ring.bounds = core.bounds
        layer?.addSublayer(ring)
        layer?.addSublayer(core)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        core.position = center
        ring.position = center
        core.shadowColor = tint.cgColor
        core.shadowOpacity = 0.9
        core.shadowRadius = 5
        core.shadowOffset = .zero
    }

    override func viewDidMoveToWindow() {
        ring.removeAllAnimations()
        guard window != nil else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1.0
        grow.toValue = 2.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.3
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
    }
}

/// 考え中のドット：3 つが、ずれて、膨らんで光る。
@MainActor final class ThinkingDotsView: NSView {
    private let tint: NSColor
    private var dots: [CALayer] = []
    private let dotSize: CGFloat

    init(tint: NSColor, dotSize: CGFloat = 6) {
        self.tint = tint
        self.dotSize = dotSize
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: dotSize * 4.6).isActive = true
        heightAnchor.constraint(equalToConstant: dotSize * 2).isActive = true
        for _ in 0..<3 {
            let dot = CALayer()
            dot.backgroundColor = tint.cgColor
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.shadowColor = tint.cgColor
            dot.shadowOpacity = 0.8
            dot.shadowRadius = 4
            dot.shadowOffset = .zero
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        for (i, dot) in dots.enumerated() {
            dot.position = CGPoint(x: dotSize * (0.9 + 1.4 * CGFloat(i)) + dotSize * 0.1, y: bounds.midY)
        }
    }

    override func viewDidMoveToWindow() {
        dots.forEach { $0.removeAllAnimations() }
        guard window != nil else { return }
        let now = CACurrentMediaTime()
        for (i, dot) in dots.enumerated() {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.55, 1.0, 0.55]
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.3, 1.0, 0.3]
            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = 1.05
            group.repeatCount = .infinity
            group.beginTime = now + 0.16 * Double(i)
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(group, forKey: "think")
        }
    }
}

/// 光が走る文字（考え中の題）：文字の上を、明るい帯が、左から右へ流れる。
@MainActor final class ShimmerLabel: NSTextField {
    private let sweep = CAGradientLayer()

    init(_ text: String, font: NSFont, color: NSColor) {
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        textColor = color
        isEditable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.colors = [NSColor(white: 1, alpha: 0.42).cgColor, NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 1, alpha: 0.42).cgColor]
        sweep.locations = [-0.4, -0.2, 0]
        layer?.mask = sweep
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        sweep.frame = bounds
    }

    override func viewDidMoveToWindow() {
        sweep.removeAllAnimations()
        guard window != nil else { return }
        let move = CABasicAnimation(keyPath: "locations")
        move.fromValue = [-0.4, -0.2, 0.0]
        move.toValue = [1.0, 1.2, 1.4]
        move.duration = 1.6
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.add(move, forKey: "shimmer")
    }
}

/// 光る縁：パネルの縁を、色が回りながら、細く光る（録音中・考え中・確認）。色は、状態ごとに替える。
@MainActor final class GlowBorderView: NSView {
    private let container = CALayer()
    private let gradient = CAGradientLayer()
    private let ring = CAShapeLayer()
    var cornerRadius: CGFloat = 18 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        container.addSublayer(gradient)
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 1.6
        container.mask = ring
        layer?.addSublayer(container)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // クリックを、そのまま通す

    /// 色を替えて、回し始める。`nil` なら、隠す。
    func show(colors: [NSColor]?) {
        guard let colors else { isHidden = true; gradient.removeAllAnimations(); return }
        gradient.colors = (colors + [colors[0]]).map { $0.cgColor }
        isHidden = false
        if gradient.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2
            spin.duration = 3.2
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "spin")
        }
    }

    override func layout() {
        super.layout()
        container.frame = bounds
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.frame = bounds
        ring.path = CGPath(roundedRect: bounds.insetBy(dx: 0.8, dy: 0.8), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }
}

/// 録音の経過時間（0:03）。画面から外れたら、止まる。
@MainActor final class ElapsedLabel: NSTextField {
    private var start = Date()
    private var timer: Timer?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        textColor = HUDStyle.primary
        alignment = .right
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 38).isActive = true
        stringValue = "0:00"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        start = Date()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        update()
    }

    private func update() {
        let seconds = Int(Date().timeIntervalSince(start))
        stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

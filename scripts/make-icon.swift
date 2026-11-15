import AppKit

// voice-control のアプリのアイコンを、コードで生成する（外部の素材は使わない。meeting-analyzer の make-icon.swift と同じ方式）。
// 使い方（リポジトリのルートで）: ./scripts/make-icon.sh   （中で swift scripts/make-icon.swift <出力先> を実行する）
// 出力：<出力先>/AppIcon.iconset/ … iconutil で AppIcon.icns にするための、各サイズの PNG
// 図柄：画面の上のパネル（HUD）と同じ、暗いガラスの色の角丸の四角に、録音の色（赤〜橙）のマイク。左右に、音の広がり（水色〜紫）。

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output directory>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

/// `size` × `size` ピクセルの PNG を作る。`draw` は、`extent` × `extent` の座標系（左下原点）で描く。
func png(size: Int, extent: CGFloat, draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / extent, y: CGFloat(size) / extent)
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

// MARK: - アプリのアイコン（1024 の座標系）

func drawAppIcon(_ ctx: CGContext) {
    // macOS のアイコンの形：1024 の中に、余白 100 を残した 824 の角丸の四角。
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 188, cornerHeight: 188, transform: nil)

    // 影つきで、下地を塗る。
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.42))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x15152A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    // 暗い藍（上）から、ほぼ黒（下）へ。
    ctx.drawLinearGradient(gradient([color(0x2C2C52), color(0x0A0A16)]), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    // マイクの後ろの、橙のにじみ。
    ctx.drawRadialGradient(gradient([color(0xFF7A30, 0.34), color(0xFF4D47, 0.0)]), startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])
    // 上端の、細い光。
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.14), color(0xFFFFFF, 0.0)]), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 800), options: [])
    ctx.restoreGState()

    // 音の広がり（左右 2 本ずつ。水色から紫へ）。
    let center = CGPoint(x: 512, y: 600)
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.setLineCap(.round)
    for (radius, width, alpha) in [(CGFloat(300), CGFloat(30), CGFloat(0.95)), (CGFloat(354), CGFloat(24), CGFloat(0.5))] {
        for side in [CGFloat(1), CGFloat(-1)] {
            let angle: CGFloat = 0.6   // 約 34°
            let path = CGMutablePath()
            if side > 0 { path.addArc(center: center, radius: radius, startAngle: -angle, endAngle: angle, clockwise: false) }
            else { path.addArc(center: center, radius: radius, startAngle: .pi - angle, endAngle: .pi + angle, clockwise: false) }
            ctx.saveGState()
            ctx.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
            ctx.clip()
            ctx.setAlpha(alpha)
            ctx.drawLinearGradient(gradient([color(0x66D1FF), color(0xB86BFA)]), start: CGPoint(x: 512 - 380, y: 0), end: CGPoint(x: 512 + 380, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()

    // マイクの受け（U 字・軸・台）。白に近い。
    ctx.saveGState()
    // 1 本の線で描く（重ねると、継ぎ目が明るく見える）
    let holder = CGMutablePath()
    holder.addArc(center: CGPoint(x: 512, y: 548), radius: 176, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    holder.move(to: CGPoint(x: 512, y: 372)); holder.addLine(to: CGPoint(x: 512, y: 296))
    holder.move(to: CGPoint(x: 430, y: 288)); holder.addLine(to: CGPoint(x: 594, y: 288))
    ctx.addPath(holder.copy(strokingWithWidth: 36, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.setFillColor(color(0xF4F4F8))
    ctx.fillPath(using: .winding)
    ctx.restoreGState()

    // マイクの頭（録音の色：橙から赤へ）。
    let capsule = CGRect(x: 394, y: 452, width: 236, height: 372)
    let capsulePath = CGPath(roundedRect: capsule, cornerWidth: 118, cornerHeight: 118, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 36, color: color(0xFF4D47, 0.55))
    ctx.addPath(capsulePath)
    ctx.setFillColor(color(0xFF6A3A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(capsulePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFA23A), color(0xFF4D47)]), start: CGPoint(x: 0, y: capsule.maxY), end: CGPoint(x: 0, y: capsule.minY), options: [])
    // 左のハイライト。
    ctx.setFillColor(color(0xFFFFFF, 0.26))
    ctx.fill(CGRect(x: capsule.minX + 26, y: capsule.minY + 70, width: 26, height: capsule.height - 140))
    // 網目の線（小さいと、見えなくなる）。
    ctx.setFillColor(color(0x7A1A10, 0.26))
    for index in 0..<3 { ctx.fill(CGRect(x: capsule.minX + 70, y: capsule.midY - 36 + CGFloat(index) * 44, width: capsule.width - 140, height: 12)) }
    ctx.restoreGState()
}

// iconutil が要る各サイズ（1x と 2x）。
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for item in sizes {
    try png(size: item.pixels, extent: 1024, draw: drawAppIcon).write(to: iconset.appendingPathComponent(item.name + ".png"))
}

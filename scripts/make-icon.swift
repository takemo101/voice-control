import AppKit

// voice-control のアプリのアイコンを、コードで生成する（外部の素材は使わない。meeting-analyzer の make-icon.swift と同じ方式）。
// 使い方（リポジトリのルートで）: ./scripts/make-icon.sh   （中で swift scripts/make-icon.swift <出力先> を実行する）
// 出力：<出力先>/AppIcon.iconset/ … iconutil で AppIcon.icns にするための、各サイズの PNG
// 図柄：深い黒藍の角丸の四角（ガラスの縁つき）に、声の波形（左右対称の丸い棒 7 本。シアン → 紫 → 珊瑚のグラデーションと、光のにじみ）。

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
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x0B0B16))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    // 深い黒藍の下地（斜め）。
    ctx.drawLinearGradient(gradient([color(0x1A1038), color(0x07070F)]), start: CGPoint(x: 120, y: 924), end: CGPoint(x: 904, y: 100), options: [])
    // 左下のマゼンタと、右上のシアンの、淡い光（奥行き）。
    ctx.drawRadialGradient(gradient([color(0xFF3D8B, 0.30), color(0xFF3D8B, 0.0)]), startCenter: CGPoint(x: 250, y: 220), startRadius: 0, endCenter: CGPoint(x: 250, y: 220), endRadius: 520, options: [])
    ctx.drawRadialGradient(gradient([color(0x3DD5FF, 0.26), color(0x3DD5FF, 0.0)]), startCenter: CGPoint(x: 800, y: 840), startRadius: 0, endCenter: CGPoint(x: 800, y: 840), endRadius: 520, options: [])
    ctx.restoreGState()

    // 声の波形：左右対称の、丸い棒 7 本（中央が最も高い）。横に、シアン → 紫 → 珊瑚のグラデーション。
    let heights: [CGFloat] = [150, 280, 430, 560, 430, 280, 150]
    let barWidth: CGFloat = 64, gap: CGFloat = 30
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let startX = 512 - total / 2
    let midY: CGFloat = 512
    let wave = CGMutablePath()
    for (index, height) in heights.enumerated() {
        let x = startX + CGFloat(index) * (barWidth + gap)
        wave.addPath(CGPath(roundedRect: CGRect(x: x, y: midY - height / 2, width: barWidth, height: height), cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    }
    let paint = gradient([color(0x35D8FF), color(0x5E7BFF), color(0xB45CFF), color(0xFF4DA6), color(0xFF8F4A)], [0, 0.26, 0.5, 0.76, 1])
    // 光のにじみ（棒の後ろ）。
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.setShadow(offset: .zero, blur: 56, color: color(0x9A6BFF, 0.5))
    ctx.addPath(wave)
    ctx.setFillColor(color(0x8B6BFF))
    ctx.fillPath()
    ctx.restoreGState()
    // 棒の本体。
    ctx.saveGState()
    ctx.addPath(wave)
    ctx.clip()
    ctx.drawLinearGradient(paint, start: CGPoint(x: startX, y: 0), end: CGPoint(x: startX + total, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // 上から下へ、ほんの少し明るく（ガラスの艶）。
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.20), color(0xFFFFFF, 0.0), color(0x000000, 0.14)], [0, 0.5, 1]), start: CGPoint(x: 0, y: midY + 290), end: CGPoint(x: 0, y: midY - 290), options: [])
    ctx.restoreGState()

    // ガラスの縁：細い光の線（上が明るく、下は消える）と、上端の反射。
    ctx.saveGState()
    ctx.addPath(bodyPath.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.38), color(0xFFFFFF, 0.04)]), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.10), color(0xFFFFFF, 0.0)]), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 760), options: [])
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

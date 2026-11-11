import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 画像の加工（切り抜き・サイズ変更・回転・形式の変換）。ImageIO・CoreGraphics だけ（外部のコマンド・ライブラリを使わない）。
/// `vc image` が使う。**言語モデルは、操作の名前と数だけを渡す**（任意のコマンド・任意の場所への書き込みは、できない）。
public enum ImageOps {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let message: String
        public var description: String { message }
    }

    public enum Format: String, CaseIterable, Sendable {
        case png, jpg, heic
        var type: UTType { switch self { case .png: .png; case .jpg: .jpeg; case .heic: .heic } }
    }

    public static let maxSide = 16_000

    public static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(message: "画像を読めません")
        }
        return image
    }

    /// 切り抜き：`left`・`top`・`width`・`height` は、画像全体を 1 とした割合（0〜1。`left + width` と `top + height` は 1 まで）。
    public static func crop(_ image: CGImage, left: Double, top: Double, width: Double, height: Double) throws -> CGImage {
        let eps = 1e-6
        guard (0...1).contains(left), (0...1).contains(top), width > 0, height > 0, left + width <= 1 + eps, top + height <= 1 + eps else {
            throw Failure(message: "切り抜きの範囲は、割合（0〜1）で、画像の中に入る必要があります（left + width ≤ 1・top + height ≤ 1）")
        }
        let w = Double(image.width), h = Double(image.height)
        let rect = CGRect(x: (left * w).rounded(), y: (top * h).rounded(), width: max(1, (width * w).rounded()), height: max(1, (height * h).rounded())).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cropped = image.cropping(to: rect) else { throw Failure(message: "切り抜けません") }
        return cropped
    }

    /// 真四角に切り抜く：短いほうの辺を一辺とする、真ん中の正方形（端の余りは、左右・上下に、半分ずつ）。
    public static func centerSquare(_ image: CGImage) throws -> CGImage {
        let side = min(image.width, image.height)
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let cropped = image.cropping(to: rect) else { throw Failure(message: "切り抜けません") }
        return cropped
    }

    /// サイズ変更：横を `width` ピクセルにする（縦は、比を保つ）。
    public static func resize(_ image: CGImage, width: Int) throws -> CGImage {
        guard (16...maxSide).contains(width) else { throw Failure(message: "横は、16〜\(maxSide) ピクセルにしてください") }
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard height <= maxSide else { throw Failure(message: "縦が大きすぎます（\(height) ピクセル）") }
        return try draw(image, size: (width, height), stretch: true, transform: { _ in })
    }

    /// サイズ変更：割合（1〜400 %）。
    public static func resize(_ image: CGImage, percent: Double) throws -> CGImage {
        guard (1...400).contains(percent) else { throw Failure(message: "割合は、1〜400 にしてください") }
        return try resize(image, width: max(16, Int((Double(image.width) * percent / 100).rounded())))
    }

    /// 回転：時計回りに 90・180・270 度。
    public static func rotate(_ image: CGImage, degrees: Int) throws -> CGImage {
        guard [90, 180, 270].contains(degrees) else { throw Failure(message: "回転は、90・180・270（時計回り）のどれかです") }
        let swap = degrees != 180
        let size = swap ? (image.height, image.width) : (image.width, image.height)
        return try draw(image, size: size, stretch: false) { context in
            let w = CGFloat(size.0), h = CGFloat(size.1)
            switch degrees {
            case 90: context.translateBy(x: 0, y: h); context.rotate(by: -.pi / 2)
            case 180: context.translateBy(x: w, y: h); context.rotate(by: .pi)
            default: context.translateBy(x: w, y: 0); context.rotate(by: .pi / 2)
            }
        }
    }

    /// `stretch`：出力の大きさに、引き伸ばして描く（サイズ変更）。false なら、元の大きさのまま、変換（回転）をかけて描く。
    private static func draw(_ image: CGImage, size: (Int, Int), stretch: Bool, transform: (CGContext) -> Void) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "画像を作れません")
        }
        context.interpolationQuality = .high
        transform(context)
        let rect = stretch ? CGRect(x: 0, y: 0, width: size.0, height: size.1) : CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw Failure(message: "画像を作れません") }
        return result
    }

    /// 書き出す（既存のファイルは、置き換える）。
    public static func write(_ image: CGImage, to url: URL, format: Format) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw Failure(message: "\(format.rawValue) で書き出せません")
        }
        let options: [CFString: Any] = format == .png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "\(format.rawValue) で書き出せません") }
    }

    /// ファイルの画像（PNG・JPEG・HEIC）を、PNG のデータにする（パネルへ渡す）。PNG は、そのまま（再び符号化しない）。読めなければ、失敗。
    public static func pngData(contentsOf url: URL) throws -> Data {
        let image = try load(url)
        if url.pathExtension.lowercased() == "png", let data = FileManager.default.contents(atPath: url.path) { return data }
        return try pngData(image)
    }

    /// PNG のデータにする（パネルへ渡す）。
    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw Failure(message: "画像を作れません") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "画像を作れません") }
        return data as Data
    }

    /// 言語モデルへ渡す画像：長いほうの辺を `maxSide` ピクセルまでに縮めた PNG（大きな画面の画像は、遅く・入力に入らないため）。
    public static func downscaledPNG(_ url: URL, maxSide: Int = 1568) throws -> Data {
        var image = try load(url)
        let longest = max(image.width, image.height)
        if longest > maxSide { image = try resize(image, width: max(16, image.width * maxSide / longest)) }
        return try pngData(image)
    }

    public static func size(of url: URL) throws -> (width: Int, height: Int) {
        let image = try load(url)
        return (image.width, image.height)
    }
}

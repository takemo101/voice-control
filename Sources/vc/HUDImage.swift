import AppKit
import ImageIO
import VCCore
import VCSkill

/// 画面の上のパネル（HUD）に出す、画像のサムネイル（画像を使うスキルが選ばれたとき）。**どの画像が使われるのか**を、見せる（F49）。
/// 画像は、作ったあと変えない（`@unchecked Sendable` の理由）。サムネイルだけ持つ（大きな画像を、HUD に持たない）。
struct HUDImage: @unchecked Sendable {
    let thumbnail: NSImage
    /// 元の画像の大きさ（ピクセル）。
    let pixelSize: CGSize
    /// 外へ送るか（`ask-agent-image`）。送るなら、琥珀色で知らせる。
    let sendsOut: Bool

    /// サムネイルの長いほうの辺（ピクセル）。確認のときの、大きな表示にも足りる。
    static let maxPixel = 520

    /// 画像を使うスキルのとき、いまのスクリーンショットから作る（画像のスキルでない・撮っていない・読めなければ nil）。
    static func current(for skill: Skill) -> HUDImage? {
        guard skill.image, case let .success(url) = ScreenshotStore.current() else { return nil }
        return load(url, sendsOut: skill.sendsScreenshot)
    }

    static func load(_ url: URL, sendsOut: Bool) -> HUDImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary)
        else { return nil }
        return HUDImage(thumbnail: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), pixelSize: CGSize(width: width, height: height), sendsOut: sendsOut)
    }
}

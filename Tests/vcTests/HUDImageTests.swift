import AppKit
import Foundation
import Testing
@testable import vc
import VCSkill

/// 画面の上のパネルに出す、画像のサムネイル：元の大きさを保ち、サムネイルは上限に収まる。画像のスキルでなければ、画像を読まない。
@Suite struct HUDImageTests {
    private func writePNG(width: Int, height: Int) throws -> URL {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hudimage-\(UUID().uuidString).png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test func keepsTheOriginalSizeAndShrinksTheThumbnail() throws {
        let url = try writePNG(width: 2000, height: 1000)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(HUDImage.load(url, sendsOut: true))
        #expect(image.pixelSize == CGSize(width: 2000, height: 1000) && image.sendsOut)
        #expect(max(image.thumbnail.size.width, image.thumbnail.size.height) <= CGFloat(HUDImage.maxPixel))
    }

    @Test func anUnreadableFileGivesNoImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hudimage-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HUDImage.load(url, sendsOut: false) == nil)
    }

    @Test func aSkillWithoutTheImageKeyNeverReadsTheScreenshot() {
        #expect(HUDImage.current(for: DefaultSkill.skill) == nil)   // `image: true` がないスキル
    }
}

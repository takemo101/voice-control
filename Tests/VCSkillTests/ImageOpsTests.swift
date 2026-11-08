import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import VCSkill

/// 画像の加工：向き・大きさ・範囲が、正しいか（左上が赤・右下が青の、4 色の画像で確かめる）。
@Suite struct ImageOpsTests {
    /// 幅 40・高さ 20：左半分が赤・右半分が青（上下は同じ）。
    private func sample() throws -> CGImage {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        return context.makeImage()!
    }

    /// (x, y)（左上が原点）の色の系統：赤は "R"・青は "B"（色の変換で、値が少しずれるので、強いほうの成分で見分ける）。
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> String {
        var data = [UInt8](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return data[0] > 200 && data[2] < 100 ? "R" : (data[2] > 200 && data[0] < 100 ? "B" : "?")
    }

    @Test func cropKeepsTheRequestedFractionFromTheTopLeft() throws {
        let right = try ImageOps.crop(sample(), left: 0.5, top: 0, width: 0.5, height: 1)
        #expect(right.width == 20 && right.height == 20)
        #expect(pixel(right, 5, 5) == "B")   // 右半分：青
        let topHalf = try ImageOps.crop(sample(), left: 0, top: 0, width: 1, height: 0.5)
        #expect(topHalf.width == 40 && topHalf.height == 10 && pixel(topHalf, 5, 5) == "R")
    }

    @Test func badCropsAreRefused() throws {
        let image = try sample()
        for (l, t, w, h) in [(0.6, 0.0, 0.5, 1.0), (-0.1, 0.0, 0.5, 1.0), (0.0, 0.0, 0.0, 1.0), (0.0, 0.5, 1.0, 0.6), (0.0, 0.0, 1.0, -1.0)] {
            #expect(throws: ImageOps.Failure.self) { try ImageOps.crop(image, left: l, top: t, width: w, height: h) }
        }
    }

    @Test func resizeKeepsTheAspectRatio() throws {
        let image = try sample()
        let small = try ImageOps.resize(image, width: 20)
        #expect(small.width == 20 && small.height == 10 && pixel(small, 2, 2) == "R" && pixel(small, 17, 2) == "B")
        let half = try ImageOps.resize(image, percent: 50)
        #expect(half.width == 20 && half.height == 10)
        #expect(throws: ImageOps.Failure.self) { try ImageOps.resize(image, width: 4) }
        #expect(throws: ImageOps.Failure.self) { try ImageOps.resize(image, percent: 0) }
    }

    /// 時計回りに 90 度：幅と高さが入れ替わり、左（赤）が、上へ来る。
    @Test func rotationTurnsClockwise() throws {
        let image = try sample()
        let right = try ImageOps.rotate(image, degrees: 90)
        #expect(right.width == 20 && right.height == 40)
        #expect(pixel(right, 10, 5) == "R" && pixel(right, 10, 35) == "B")   // 上が赤・下が青
        let half = try ImageOps.rotate(image, degrees: 180)
        #expect(half.width == 40 && half.height == 20 && pixel(half, 5, 5) == "B" && pixel(half, 35, 5) == "R")
        let left = try ImageOps.rotate(image, degrees: 270)
        #expect(pixel(left, 10, 5) == "B" && pixel(left, 10, 35) == "R")
        #expect(throws: ImageOps.Failure.self) { try ImageOps.rotate(image, degrees: 45) }
    }

    @Test func writeAndReadBackInEachFormat() throws {
        let image = try sample()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for format in ImageOps.Format.allCases {
            let url = dir.appendingPathComponent("a.\(format.rawValue)")
            try ImageOps.write(image, to: url, format: format)
            let size = try ImageOps.size(of: url)
            #expect(size.width == 40 && size.height == 20, "\(format)")
        }
    }

    @Test func theImageForTheModelIsShrunkToTheLongestSide() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = try ImageOps.resize(sample(), width: 4000)   // 4000 × 2000
        let url = dir.appendingPathComponent("big.png")
        try ImageOps.write(big, to: url, format: .png)
        let data = try ImageOps.downscaledPNG(url, maxSide: 1000)
        let shrunk = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(shrunk.width == 1000 && shrunk.height == 500)
        let small = try ImageOps.downscaledPNG(dir.appendingPathComponent("big.png"), maxSide: 5000)   // 縮めない
        let kept = try #require(CGImageSourceCreateWithData(small as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(kept.width == 4000)
    }
}

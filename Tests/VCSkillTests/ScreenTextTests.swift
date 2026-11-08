import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import VCSkill

/// 文字の読み取り：自作の画像（白地に黒い文字）を読めること、行が上から下へ並ぶこと。
@Suite struct ScreenTextTests {
    fileprivate func render(_ lines: [String]) throws -> URL {
        let width = 900, rowHeight = 90, height = rowHeight * lines.count + 40
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 48, nil)
        for (i, line) in lines.enumerated() {
            let attributed = CFAttributedStringCreate(nil, line as CFString, [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true] as CFDictionary)!
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.textPosition = CGPoint(x: 30, y: height - 30 - rowHeight * (i + 1) + 25)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString).png")
        try ImageOps.write(context.makeImage()!, to: url, format: .png)
        return url
    }

    @Test func readsJapaneseAndEnglishLinesInOrder() throws {
        let url = try render(["Invoice 12345", "請求書の合計金額"])
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try ScreenText.recognize(url)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.first?.contains("12345") == true)
        #expect(lines.last?.contains("請求書") == true)
    }

    @Test func aBlankImageGivesNoText() throws {
        let url = try render([])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ScreenText.recognize(url).isEmpty)
    }

    @Test func linesAreOrderedTopToBottomThenLeftToRight() {
        let lines = [
            ScreenText.Line(text: "下", top: 0.3, left: 0.1, height: 0.1),
            ScreenText.Line(text: "右上", top: 0.91, left: 0.6, height: 0.1),
            ScreenText.Line(text: "左上", top: 0.9, left: 0.1, height: 0.1),
        ]
        #expect(ScreenText.text(from: lines) == "左上\n右上\n下")
    }
}

extension ScreenTextTests {
    /// 画像のデータ（ファイルを経由しない）からも、同じ文字を読める。読めないデータは、理由つきで失敗する。
    @Test func readsFromImageDataToo() throws {
        let url = try render(["Invoice 12345"])
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try ScreenText.recognize(data: Data(contentsOf: url))
        #expect(text.contains("12345"))
        #expect(throws: ScreenText.Failure.self) { try ScreenText.recognize(data: Data("not an image".utf8)) }
    }
}

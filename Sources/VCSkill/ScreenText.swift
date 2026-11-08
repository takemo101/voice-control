import CoreGraphics
import Foundation
import ImageIO
import Vision

/// 画像の中の文字を読み取る（Apple の Vision フレームワークの文字認識。**この Mac の中だけ**で動く。言語モデルを通さない：速く、写し間違い・補足をしない）。
/// 画像のパネルの「文字起こし」と、`vc see`（質問に添える文字）が使う。
public enum ScreenText {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let message: String
        public var description: String { message }
    }

    /// 日本語と英語（認識の言語の優先順）。
    static let languages = ["ja-JP", "en-US"]

    /// 読み取った文字。上から下・行ごとに、改行でつなぐ。文字がなければ、空の文字列。
    public static func recognize(_ url: URL) throws -> String {
        do { return try recognize(image: try ImageOps.load(url)) } catch let failure as ImageOps.Failure { throw Failure(message: failure.message) }
    }

    /// 画像のデータ（PNG など）から読み取る（画像のパネルが使う：ファイルを、経由しない）。
    public static func recognize(data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "画像を読めません") }
        return try recognize(image: image)
    }

    static func recognize(image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { throw Failure(message: "文字を読み取れませんでした（\(error.localizedDescription)）") }
        return text(from: (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Line(text: $0.string, top: observation.boundingBox.maxY, left: observation.boundingBox.minX, height: observation.boundingBox.height) }
        })
    }

    /// 最初の文字認識は、システムが認識のモデルを準備するので、30 秒ほどかかる（2 回目からは、0.2 秒ほど）。使う前に、小さな白い画像で済ませておく（別のスレッドで。結果は使わない）。
    public static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            guard let image = context.makeImage() else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])   // try?: 準備だけ。失敗しても、本番の読み取りが、同じ失敗を返す
        }
    }

    struct Line: Equatable {
        let text: String
        /// 上端（画像の下端が 0・上端が 1）と、左端・高さ（いずれも画像全体を 1 とした割合）。
        let top: Double
        let left: Double
        let height: Double
    }

    /// 行を、上から下へ並べる（同じ段にある行は、左から右）。同じ段：上端の差が、行の高さの半分より小さい。
    static func text(from lines: [Line]) -> String {
        let sorted = lines.sorted { a, b in
            abs(a.top - b.top) < min(a.height, b.height) / 2 ? a.left < b.left : a.top > b.top
        }
        return sorted.map(\.text).joined(separator: "\n")
    }
}

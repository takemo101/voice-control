import CoreGraphics
import Foundation
import VCCore

/// `vc image <操作>`：いまのスクリーンショットを加工して、保存する（言語モデルが呼ぶ。引数の形は、ここで一度だけ検査する）。
/// - `crop <部分>`：切り抜き。部分は `left-half`・`right-half`・`top-half`・`bottom-half`・`center`（言語モデルが、数を間違えない形）
/// - `crop [--left F] [--top F] [--width F] [--height F]`：切り抜き（割合 0〜1。省略は、左上から全体）
/// - `resize --width N` / `resize --percent N`：サイズ変更（比を保つ）
/// - `rotate 90|180|270`：時計回りの回転
/// - `convert png|jpg|heic`：形式の変換
/// 結果は、新しいファイルとして、保存先（`~/Pictures/voice-control`。決まった場所：モデルは、場所・名前を決められない）へ書く。**いまのスクリーンショットも、結果に置き換える**（続けて、サイズ変更などができる）。元の画像は、変えない（古い版は、残らない）。
struct ImageEditing {
    static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/voice-control")
    }

    /// 切り抜きの部分（割合）。
    static let cropParts: [String: (left: Double, top: Double, width: Double, height: Double)] = [
        "left-half": (0, 0, 0.5, 1), "right-half": (0.5, 0, 0.5, 1), "top-half": (0, 0, 1, 0.5), "bottom-half": (0, 0.5, 1, 0.5), "center": (0.25, 0.25, 0.5, 0.5),
    ]

    var storeDirectory: URL = ScreenshotStore.directory
    var outputDirectory: URL = ImageEditing.defaultOutputDirectory
    var now: Date = Date()

    func run(_ arguments: [String]) -> Result<String, ToolFailure> {
        do { return .success(try apply(arguments)) }
        catch let failure as ToolFailure { return .failure(failure) }
        catch { return .failure(ToolFailure(exitCode: 1, message: "\(error)")) }
    }

    private func usageError(_ text: String) -> ToolFailure { ToolFailure(exitCode: 2, message: text) }

    private func apply(_ arguments: [String]) throws -> String {
        guard let operation = arguments.first else { throw usageError("operation needed: crop | resize | rotate | convert") }
        let rest = Array(arguments.dropFirst())
        let source: URL
        switch ScreenshotStore.current(now: now, directory: storeDirectory) {
        case let .success(url): source = url
        case let .failure(missing): throw ToolFailure(exitCode: 1, message: "\(missing)")
        }
        var image = try loadImage(source)
        var format = ImageOps.Format.png
        do {
            switch operation {
            case "crop":
                if rest.count == 1, !rest[0].hasPrefix("--") {
                    guard let part = Self.cropParts[rest[0]] else { throw usageError("unknown part \(rest[0]) (\(Self.cropParts.keys.sorted().joined(separator: ", ")))") }
                    image = try ImageOps.crop(image, left: part.left, top: part.top, width: part.width, height: part.height)
                } else {
                    let o = try Options(rest, numbers: ["--left", "--top", "--width", "--height"])
                    image = try ImageOps.crop(image, left: o.number("--left") ?? 0, top: o.number("--top") ?? 0, width: o.number("--width") ?? 1, height: o.number("--height") ?? 1)
                }
            case "resize":
                let o = try Options(rest, numbers: ["--width", "--percent"])
                switch (o.number("--width"), o.number("--percent")) {
                case let (width?, nil):
                    guard width == width.rounded() else { throw usageError("--width must be a whole number of pixels") }
                    image = try ImageOps.resize(image, width: Int(width))
                case let (nil, percent?): image = try ImageOps.resize(image, percent: percent)
                default: throw usageError("give exactly one of --width <pixels> or --percent <1-400>")
                }
            case "rotate":
                guard rest.count == 1, let degrees = Int(rest[0]) else { throw usageError("rotate needs 90, 180 or 270 (clockwise)") }
                image = try ImageOps.rotate(image, degrees: degrees)
            case "convert":
                guard rest.count == 1 else { throw usageError("convert needs png, jpg or heic") }
                let name = rest[0].lowercased() == "jpeg" ? "jpg" : rest[0].lowercased()
                guard let chosen = ImageOps.Format(rawValue: name) else { throw usageError("format must be png, jpg or heic") }
                format = chosen
            default: throw usageError("unknown operation \(operation) (crop, resize, rotate, convert)")
            }
        } catch let failure as ImageOps.Failure { throw ToolFailure(exitCode: 2, message: failure.message) }

        let saved = try save(image, format: format)
        // いまのスクリーンショットを、結果（PNG）に置き換える
        let temporary = storeDirectory.appendingPathComponent("next-\(UUID().uuidString).png")
        try ScreenshotStore.prepare(directory: storeDirectory)
        try ImageOps.write(image, to: temporary, format: .png)
        try ScreenshotStore.replace(with: temporary, directory: storeDirectory)
        return "saved: \(saved.path) (\(image.width)x\(image.height), \(format.rawValue))"
    }

    private func loadImage(_ url: URL) throws -> CGImage {
        do { return try ImageOps.load(url) } catch { throw ToolFailure(exitCode: 1, message: "\(error)") }
    }

    /// `shot-年月日-時分秒.<形式>`（同じ秒に重なったら、連番）。
    private func save(_ image: CGImage, format: ImageOps.Format) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = "shot-\(stamp.string(from: now))"
        var url = outputDirectory.appendingPathComponent("\(base).\(format.rawValue)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = outputDirectory.appendingPathComponent("\(base)-\(n).\(format.rawValue)"); n += 1 }
        do { try ImageOps.write(image, to: url, format: format) } catch { throw ToolFailure(exitCode: 1, message: "保存できません（\(error)）") }
        return url
    }

    /// `--名前 数` の並び（決まった名前だけ。ほかは、エラー）。
    private struct Options {
        private var values: [String: Double] = [:]
        init(_ arguments: [String], numbers: Set<String>) throws {
            var i = 0
            while i < arguments.count {
                let flag = arguments[i]
                guard numbers.contains(flag) else { throw ToolFailure(exitCode: 2, message: "unknown option \(flag) (\(numbers.sorted().joined(separator: ", ")))") }
                guard i + 1 < arguments.count, let value = Double(arguments[i + 1]), value.isFinite else { throw ToolFailure(exitCode: 2, message: "\(flag) needs a number") }
                guard values[flag] == nil else { throw ToolFailure(exitCode: 2, message: "\(flag) given twice") }
                values[flag] = value
                i += 2
            }
        }
        func number(_ flag: String) -> Double? { values[flag] }
    }
}

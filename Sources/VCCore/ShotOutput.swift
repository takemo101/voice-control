import Foundation

/// 加工・保存した画像の置き場所と、名前（`~/Pictures/voice-control/shot-<年月日-時分秒>.<形式>`）。**決まった場所**：言語モデルも、パネルも、場所・名前を決められない。
public enum ShotOutput {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/voice-control")
    }

    /// まだ使われていない、保存先（同じ秒に重なったら、連番）。`directory` を作る。
    public static func nextURL(in directory: URL = ShotOutput.directory, ext: String, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = "shot-\(stamp.string(from: now))"
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = directory.appendingPathComponent("\(base)-\(n).\(ext)"); n += 1 }
        return url
    }
}

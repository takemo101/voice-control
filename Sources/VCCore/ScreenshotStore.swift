import Foundation

/// いまのスクリーンショット（声で指示する相手の画像）の置き場所。`~/.voice-control/shot/current.png` の 1 枚だけ。
/// **画面の内容なので、扱いを絞る**：ディレクトリは自分だけ（0700）・ファイルも自分だけ（0600）・**古くなったら使わない**（`timeToLive`）・新しい 1 枚が、前の 1 枚を置き換える・終了のときに消す。
/// ログ・ほかの場所へは、コピーしない（加工した画像の保存は、利用者の依頼のときだけ。`vc image`）。
public enum ScreenshotStore {
    /// 撮ってから、使える時間（秒）。過ぎたら、「古い」として、使わない（撮り直す）。
    public static let timeToLive: TimeInterval = 180
    /// 案内に書く、分。
    public static var timeToLiveMinutes: Int { Int(timeToLive / 60) }

    public static var directory: URL { VoiceControlHome.root.appendingPathComponent("shot") }
    public static var currentFile: URL { directory.appendingPathComponent("current.png") }
    /// コピーした画像を、`vc see` が読むために、書き出す場所（使い終わったら消す）。
    public static var clipboardFile: URL { directory.appendingPathComponent("clipboard.png") }

    public enum Missing: Error, Equatable, CustomStringConvertible {
        case none
        case expired(seconds: Int)
        public var description: String {
            switch self {
            case .none: return "スクリーンショットがありません。先に、ショートカットで撮ってください（vc hotkey set-shot。いま撮るなら vc shot）"
            case let .expired(seconds): return "スクリーンショットが古いです（\(seconds) 秒前。\(Int(ScreenshotStore.timeToLive)) 秒まで）。撮り直してください"
            }
        }
    }

    /// 置き場所を作る（自分だけが読める）。
    public static func prepare(directory: URL = ScreenshotStore.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// `source` の画像を、いまのスクリーンショットにする（前のものは、置き換わる）。`source` は、移す（残さない）。
    public static func replace(with source: URL, directory: URL = ScreenshotStore.directory) throws {
        try prepare(directory: directory)
        let target = directory.appendingPathComponent("current.png")
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// 使えるスクリーンショット（なければ、ない・古い）。
    public static func current(now: Date = Date(), directory: URL = ScreenshotStore.directory) -> Result<URL, Missing> {
        let file = directory.appendingPathComponent("current.png")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), let modified = attributes[.modificationDate] as? Date else { return .failure(.none) }   // try?: ファイルがなければ、「ない」
        let age = now.timeIntervalSince(modified)
        return age > timeToLive ? .failure(.expired(seconds: Int(age))) : .success(file)
    }

    /// コピーした画像の書き出しを、消す。
    public static func clearClipboardExport() {
        try? FileManager.default.removeItem(at: clipboardFile)   // try?: 後片付け。なくても、よい
    }

    /// 消す（終了のとき）。なくても、よい。
    public static func clear(directory: URL = ScreenshotStore.directory) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("clipboard.png"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("current.png"))   // try?: 後片付け。消えていなくても、次の置き換えで消える
    }
}

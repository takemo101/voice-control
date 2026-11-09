import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VCCore

/// **画像を使うスキルが、画像をどこから取るか**（フロントマター `image:`。`vc see --from`）。入口を 1 つにして、取り方（置き場所・古さ・なければ何と言うか）を、ここに集める。
/// - `screenshot`：撮ったスクリーンショット（`ScreenshotStore`。撮ってから 3 分）。
/// - `clipboard`：**コピーした画像**（クリップボード。画像のデータか、Finder でコピーした画像ファイル）。
/// - `any`：**どちらでも**（スキルの `image: any`・`vc see` の既定）。**どちらを見るかは、コードが決める**（`resolve(for:)`）：言語モデルは、選ばない。
/// **言語モデルは、パスもファイルも、渡せない**（取り先は、この 2 つだけ：決まった場所）。画像は、この Mac の中のモデルだけが見る（外へ送るスキルは、別：`ask-agent-image`）。
public enum ImageSource: String, Sendable, Equatable, CaseIterable, Hashable {
    case screenshot, clipboard, any

    /// 依頼に、これらの言葉があれば、コピーした画像を見る（「コピーした画像を…」）。**なければ、撮ったスクリーンショットが先**（なければ、コピーした画像）。
    static let clipboardWords = ["コピー", "クリップボード"]

    /// 実際に見る取り先（`any` を、依頼の文と、いまあるものから決める。`screenshot`・`clipboard` は、そのまま）。**言語モデルが、決めない**：画面の上のパネルに出す画像と、`vc see` が見る画像が、必ず同じになる。
    /// 「コピー」と言ったのに、コピーした画像がないときは、スクリーンショットで代わりにしない（案内が出る）。
    public func resolve(for request: String, unavailable: (ImageSource) -> Missing? = { $0.missing }) -> ImageSource {
        guard self == .any else { return self }
        if ImageSource.clipboardWords.contains(where: request.contains) { return .clipboard }
        if unavailable(.screenshot) == nil { return .screenshot }
        if unavailable(.clipboard) == nil { return .clipboard }
        return .screenshot   // どちらもない：案内は、`missing`
    }

    /// フロントマターの `image:` の値（`true` は、`screenshot`）。
    public static func parse(_ text: String) -> ImageSource? {
        let value = text.lowercased()
        if ["true", "yes", "on"].contains(value) { return .screenshot }
        return ImageSource(rawValue: value)
    }

    public enum Missing: Error, Equatable, CustomStringConvertible, Sendable {
        case screenshot(ScreenshotStore.Missing)
        case clipboardEmpty
        /// コピーしてあるものが、画像ではない（形式の名前だけ持つ：中身は、持たない）。
        case clipboardNotAnImage(formats: [String])
        case clipboardUnreadable
        case clipboardTooLarge
        /// `any`：どちらも、ない。
        case noImage

        public var description: String {
            switch self {
            case let .screenshot(missing): return "\(missing)"
            case .clipboardEmpty: return "クリップボードに画像がありません。画像をコピーしてから、頼んでください"
            case let .clipboardNotAnImage(formats): return "クリップボードにあるのは、画像ではありません（形式：\(formats.prefix(6).map { String($0.prefix(60)) }.joined(separator: "・"))）。画像をコピーしてから、頼んでください"
            case .clipboardUnreadable: return "クリップボードの画像を読めません"
            case .noImage: return "スクリーンショットも、コピーした画像も、ありません。画面を撮る（ショートカット）か、画像をコピーしてから、頼んでください"
            case .clipboardTooLarge: return "クリップボードの画像が大きすぎます（\(ImageSource.maxClipboardMegabytes) MB まで）"
            }
        }
    }

    static let maxClipboardMegabytes = 50

    /// いま使えるか（なければ、理由）。**ファイルを書かない**（振り分けのたびに呼ぶ軽い確認）。
    public var missing: Missing? {
        switch self {
        case .screenshot:
            if case let .failure(why) = ScreenshotStore.current() { return .screenshot(why) } else { return nil }
        case .clipboard:
            return ClipboardImage.missing(NSPasteboard.general)
        case .any:
            return (ImageSource.screenshot.missing == nil || ImageSource.clipboard.missing == nil) ? nil : .noImage
        }
    }

    /// 画像のファイル（なければ、理由）。クリップボードは、書き出す（`~/.voice-control/shot/clipboard.png`。自分だけが読める）。**使い終わったら、`discard()`**。
    public func materialize(for request: String = "") -> Result<URL, Missing> {
        switch resolve(for: request) {
        case .screenshot:
            return ScreenshotStore.current().mapError { .screenshot($0) }
        case .clipboard:
            return ClipboardImage.export(NSPasteboard.general)
        case .any:
            return .failure(.noImage)   // `resolve` が、必ず、どちらかにする
        }
    }

    /// 書き出した画像を、消す（クリップボードだけ。スクリーンショットは、期限で消える）。
    public func discard() {
        if self != .screenshot { ScreenshotStore.clearClipboardExport() }
    }
}

/// クリップボードの画像：画像のデータ（PNG・TIFF・JPEG…）か、Finder でコピーした画像ファイル。
enum ClipboardImage {
    /// 画像として読める型（先に見つかったものを使う）。
    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]

    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// 画像があるか（型だけ見る：ファイルを読まない）。**AppKit が画像と見るもの**（`NSImage.canInit`：PNG・TIFF・JPEG・GIF・PDF など）と、Finder でコピーした画像ファイル（1 つ）。
    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if imageTypes.contains(where: types.contains) || NSImage.canInit(with: pasteboard) { return true }
        let urls = fileURLs(pasteboard)
        return urls.count == 1 && isImageFile(urls[0])   // Finder で、画像のファイルを 1 つだけコピーした
    }

    /// 使えない理由（使えるなら nil）。コピーしてあるものが画像でないときは、**形式の名前**を添える（何がコピーされているか、分かるように：中身は、出さない）。
    static func missing(_ pasteboard: NSPasteboard) -> ImageSource.Missing? {
        if hasImage(pasteboard) { return nil }
        let formats = (pasteboard.types ?? []).map(\.rawValue)
        return formats.isEmpty ? .clipboardEmpty : .clipboardNotAnImage(formats: formats)
    }

    /// PNG にして、書き出す（大きさの上限つき）。
    static func export(_ pasteboard: NSPasteboard, directory: URL = ScreenshotStore.directory) -> Result<URL, ImageSource.Missing> {
        let limit = ImageSource.maxClipboardMegabytes * 1_000_000
        var raw: Data?
        let types = pasteboard.types ?? []
        if let type = imageTypes.first(where: types.contains) { raw = pasteboard.data(forType: type) }
        if raw == nil, case let urls = fileURLs(pasteboard), urls.count == 1, isImageFile(urls[0]) {
            if let size = (try? urls[0].resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > limit { return .failure(.clipboardTooLarge) }   // try?: 読めなければ、あとの読み込みで、失敗にする
            raw = try? Data(contentsOf: urls[0])   // try?: 読めなければ、nil（読めない画像として、扱う）
        }
        if raw == nil, NSImage.canInit(with: pasteboard) { raw = NSImage(pasteboard: pasteboard)?.tiffRepresentation }   // GIF・PDF など：AppKit に、画像にしてもらう
        guard let raw else { return .failure(missing(pasteboard) ?? .clipboardEmpty) }
        guard raw.count <= limit else { return .failure(.clipboardTooLarge) }
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = try? ImageOps.pngData(image)   // try?: 変換できなければ、読めない画像として、扱う
        else { return .failure(.clipboardUnreadable) }
        do {
            try ScreenshotStore.prepare(directory: directory)
            let url = directory.appendingPathComponent("clipboard.png")
            try png.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return .success(url)
        } catch {
            return .failure(.clipboardUnreadable)
        }
    }
}

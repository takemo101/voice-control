import AppKit
import Foundation
import ImageIO
import VCCore

/// Markdown の画像（`![説明](場所)`）を、**この Mac の中のファイルだけ**、文章の中に出す（エージェントが作った画像・作業フォルダの画像を、会話で見られる）。
/// - **ネットワークの画像は、取りに行かない**（URL が、利用者の知らないところへ、通信を起こす：仕様の安全の指針）。リンクの文字（「🖼 説明」）のまま。
/// - **読んでよい場所**を、限る（エージェントが書いた「場所」は、非信頼の文字）：会話の作業フォルダ・一時フォルダ・エージェント自身の置き場（agy・opencode）・`~/.voice-control`。それ以外（例：`~/Pictures`・`~/.ssh`）の画像は、リンクのまま。シンボリックリンク・`..` は、実際の場所に直して、判定する。
/// - 画像として読めないもの・大きすぎるもの（30 MB 超）は、出さない。表示は、長辺 2000 画素までに縮める（画面に出すだけ：ファイルは、動かさない・コピーしない・残さない）。
enum MarkdownImage {
    static let maxBytes = 30_000_000
    static let maxPixels = 2000

    /// 読んでよい場所（実際の場所）。`base`：会話の作業フォルダ。
    static func roots(base: URL?, home: String = NSHomeDirectory()) -> [String] {
        var places = [NSTemporaryDirectory(), "/tmp", home + "/.voice-control", home + "/.gemini/antigravity-cli", home + "/.local/share/opencode", home + "/.codex/generated_images"]
        if let base { places.append(base.path) }
        return places.compactMap(RealPath.existing)
    }

    /// `path` の実際の場所。**読んでよい場所の中**でなければ（外・ない）、nil。画像と、ファイルのリンクが、同じ判定を使う。
    static func readable(_ path: String, base: URL?, home: String = NSHomeDirectory()) -> String? {
        guard let real = RealPath.existing(path), roots(base: base, home: home).contains(where: { RealPath.isInside(real, root: $0) }) else { return nil }
        return real
    }

    /// 画像のファイル（読んでよいときだけ）。`url`：Markdown に書かれた場所（`file://`・絶対パス・作業フォルダからの相対）。
    static func file(for url: URL, base: URL?, home: String = NSHomeDirectory()) -> URL? {
        var candidate = url
        if url.scheme == nil || url.scheme?.isEmpty == true {
            let path = url.path.removingPercentEncoding ?? url.path
            candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : (base.map { $0.appendingPathComponent(path) } ?? URL(fileURLWithPath: path))
        }
        guard candidate.isFileURL else { return nil }   // http・https・data などは、出さない
        guard let real = readable(candidate.path, base: base, home: home) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: real)
        guard attributes?[.type] as? FileAttributeType == .typeRegular, let size = attributes?[.size] as? Int, size > 0, size <= maxBytes else { return nil }
        return URL(fileURLWithPath: real)
    }

    /// 画像（長辺を `maxPixels` までに縮める）。画像として読めなければ nil。
    static func image(at file: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // 点の大きさは、画素の半分（網膜）。大きい画像は、置かれた幅に合わせて、さらに縮む（`DiagramAttachment`）
        return NSImage(cgImage: cg, size: CGSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }
}

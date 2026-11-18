import AppKit
import Foundation

/// Markdown のリンクの、**開いてよいか・どう開くか**（**純粋**：`NSWorkspace` は、`DiagramTextView` が呼ぶ）。リンクの場所は、エージェント（非信頼）が書いた文字。
/// - `http`・`https`・`mailto` は、そのまま。
/// - **この Mac の中のファイル**（`file://`・絶対パス・**作業フォルダからの相対**：エージェントが、作ったファイルを、`security-news-detail.md` のように書く）は、`MarkdownImage` と**同じ、読んでよい場所**の中の、**実在するファイル**だけ。場所が違う・ないものは、リンクにしない（押しても、何も起きない：以前は、相対の場所を、そのまま開こうとして、Finder が「アプリケーションを開けません（-50）」と出した）。
/// - ほかの種類（`javascript:`・独自の URL など）は、リンクにしない。
enum MarkdownLink {
    enum Action: Equatable {
        /// 既定のアプリで開く（文書・画像など。**実行されるものは、開かない**）。
        case open
        /// Finder で、場所を示す（フォルダ・アプリ・スクリプト・知らない種類：開くと、実行されうる）。
        case reveal
    }

    /// 開いてよい文書・画像の拡張子（小文字）。
    static let openable: Set<String> = ["md", "markdown", "txt", "text", "csv", "tsv", "json", "log", "yaml", "yml", "toml", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    /// リンクの、実際の行き先（開いてよいもの）。なければ nil（リンクにしない）。`base`：会話の作業フォルダ。
    static func resolve(_ url: URL, base: URL?, home: String = NSHomeDirectory()) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "mailto"].contains(scheme) { return url }
        guard scheme.isEmpty || scheme == "file" else { return nil }
        let path = url.path.removingPercentEncoding ?? url.path
        guard !path.isEmpty else { return nil }
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.map { $0.appendingPathComponent(path) }
        guard let candidate else { return nil }
        guard let real = MarkdownImage.readable(candidate.path, base: base, home: home) else { return nil }
        return URL(fileURLWithPath: real)
    }

    /// ファイルのリンクを、どう開くか（ディレクトリ・実行ファイル・知らない拡張子は、示すだけ）。
    static func action(for file: URL, isDirectory: Bool = false, isExecutable: Bool = false) -> Action {
        guard !isDirectory, !isExecutable, openable.contains(file.pathExtension.lowercased()) else { return .reveal }
        return .open
    }

    /// 実際に開く（ファイルのリンクだけ。http などは、標準の動きに任せる：呼ばない）。
    @MainActor static func openFile(_ file: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
        guard exists else { return }
        switch action(for: file, isDirectory: isDirectory.boolValue, isExecutable: !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: file.path)) {
        case .open: NSWorkspace.shared.open(file)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}

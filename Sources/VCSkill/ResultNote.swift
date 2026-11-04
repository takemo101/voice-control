import Foundation

/// スキルの返事（Markdown）を、一時ディレクトリのファイルにする（`result: markdown-note` のスキル）。
/// 画面の内容から作った文章が入るので、利用者だけが読める（ディレクトリ 700・ファイル 600）。消さない（OS の一時領域に任せる）。
enum ResultNote {
    static let directoryName = "voice-control-notes"

    /// `base`（既定は、`$TMPDIR`）の下の `voice-control-notes/note-<日時>-<4 桁>.md` に書いて、その場所を返す。
    static func write(_ markdown: String, in base: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true), now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()   // 同じ秒に 2 回でも、上書きしない
        let file = directory.appendingPathComponent("note-\(formatter.string(from: now))-\(suffix).md")
        guard fm.createFile(atPath: file.path, contents: Data(unfenced(markdown).utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }

    /// 返事全体が、``` で囲まれていたら、外す（言語モデルが、Markdown を、コードブロックに入れて返すことがある）。
    static func unfenced(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2, lines.first?.hasPrefix("```") == true, lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { return trimmed }
        lines.removeFirst(); lines.removeLast()
        return lines.joined(separator: "\n")
    }
}

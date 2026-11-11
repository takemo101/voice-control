import Foundation

/// 結果の返事を、声で読む文にする（`vc speak on`）。**短い返事（「完了：〇〇」「失敗：〇〇」）だけ**を読む：長い文章（ウィンドウに出す結果）は、読まない。
enum SpokenReply {
    /// 読む文の長さの上限（これより長い返事は、読まない）。
    static let maxLength = 80

    /// 成功の返事（`done: …`）を、読む文にする。形が違う・空・長すぎるときは nil（読まない）。
    static func success(_ reply: String) -> String? {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("done:") else { return nil }
        let body = text.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= maxLength, !body.contains("\n") else { return nil }
        return body
    }

    /// 失敗の知らせを、読む文にする。「失敗しました。」＋ 理由の最初の文（長ければ、理由は読まない）。
    static func failure(_ message: String) -> String {
        var reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.lowercased().hasPrefix("failed:") { reason = String(reason.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let first = reason.split(whereSeparator: { "。\n".contains($0) }).first.map(String.init) ?? ""
        guard !first.isEmpty, first.count <= maxLength else { return "失敗しました" }
        return "失敗しました。\(first)"
    }
}

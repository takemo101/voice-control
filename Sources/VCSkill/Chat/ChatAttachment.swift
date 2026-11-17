import Foundation
import VCCore

/// 会話に添える、画像・文章（**添付**）。**添えるかどうかは、コードが決める**（言語モデルは、決めない・パスも渡せない。撮ったスクリーンショットを使うかは、`ChatImageUse` の判定〔Tiny-Jev〕。ここは、言葉で決める部分：コピーした画像・文章と、判定できないときの代わり）：
/// 「この画像」「画面」「スクショ」などと言えば、画像（撮ったスクリーンショット／コピーした画像。`ImageSource`）・「コピーした文章」「クリップボード」などと言えば、コピーした文章。
/// 画像は、**1 度だけ、文字（説明と、画像の中の文字）にして**、質問に入れる（毎回、画像を渡すと、文脈がすぐ埋まる）。同じ画像は、2 度、添えない。
public enum ChatAttachments {
    public struct Wants: Equatable, Sendable {
        public var image: Bool
        public var text: Bool
    }

    static let imageWords = ["画像", "画面", "スクショ", "スクリーンショット", "キャプチャ", "写真", "この図", "この表"]
    /// 画像を作る依頼の言葉（「画像を作って」「イラストを描いて」）と、手元の画像を指す言葉（「この」「コピーした」「撮った」）。
    static let generationWords = ["生成", "作って", "作成", "つくって", "描いて", "かいて", "出力して", "イラスト"]
    static let referringWords = ["この", "その", "あの", "これ", "それ", "コピー", "貼", "添付", "撮った", "スクショ", "スクリーンショット", "キャプチャ"]
    static let textWords = ["コピーした", "コピー", "クリップボード", "この文章", "このテキスト"]

    /// 何を添えたいか。**画像の言葉があれば、画像**（「コピーした画像」の「コピー」は、画像の取り先を決めるだけ）。なければ、文章の言葉で、コピーした文章。
    public static func wants(_ request: String) -> Wants {
        // ファイル名（`note.txt`）が出ているときの「コピー」は、ファイルのコピー（クリップボードの文章ではない）
        if FileNames.contains(in: request) { return Wants(image: false, text: false) }
        if imageWords.contains(where: request.contains) {
            // 「画像を生成して」は、画像を**作る**依頼：コピーした画像を、貼る確認を出さない（「この画像から…」「コピーした画像を…」のように、手元の画像を指していれば、画像）
            if generationWords.contains(where: request.contains), !referringWords.contains(where: request.contains) { return Wants(image: false, text: false) }
            return Wants(image: true, text: false)
        }
        if textWords.contains(where: request.contains) { return Wants(image: false, text: true) }
        return Wants(image: false, text: false)
    }

    public struct Attachment: Equatable, Sendable {
        /// 「画像」「コピーした文章」など。
        public let label: String
        public let body: String
        /// 重複を避けるための印（同じものは、2 度、添えない）。
        public let key: String
        public init(label: String, body: String, key: String) { self.label = label; self.body = body; self.key = key }
    }

    static let maxTextCharacters = 2500
    static let maxDigestCharacters = 1500

    /// 質問の文字：添付を、先に（【添付：…】）、利用者の質問を、あとに。
    public static func compose(question: String, attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return question }
        let blocks = attachments.map { "【添付：\($0.label)】\n\($0.body)\n【添付ここまで】" }
        return blocks.joined(separator: "\n\n") + "\n\n質問：" + question
    }

    /// コピーした文章の添付（長ければ、先頭だけ。切ったことを書く）。空なら nil。
    public static func textAttachment(from clipboard: String) -> Attachment? {
        let text = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let body = text.count > maxTextCharacters ? String(text.prefix(maxTextCharacters)) + "\n（長いので、先頭の \(maxTextCharacters) 文字だけ）" : text
        return Attachment(label: "コピーした文章", body: body, key: "text-\(text.count)-\(fingerprint(Data(text.utf8)))")
    }

    /// 画像の添付：画像の内容を、文字にする（この Mac の中のモデル。`VisionModel`：説明と、画像の中の文字）。
    static let digestQuestion = "この画像の内容を、日本語で、あとで質問されても答えられるように、詳しく書き出してください。画面なら、アプリ名・見出し・表・数値・エラー文などを、正確に。"

    public struct Failure: Error, Equatable, Sendable { public let message: String }

    public static func imageAttachment(file: URL, engine: Engine, cancel: CancelToken?) -> Result<Attachment, Failure> {
        switch VisionModel.ask(image: file, question: digestQuestion, engine: engine, cancel: cancel) {
        case let .success(text):
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = body.count > maxDigestCharacters ? String(body.prefix(maxDigestCharacters)) + "…" : body
            return .success(Attachment(label: "画像（内容を文字にしたもの）", body: clipped, key: "image-\(fingerprint(file))"))
        case let .failure(failure): return .failure(Failure(message: failure.message))
        }
    }

    /// 内容の印：大きさと、先頭 64 KB の FNV-1a（暗号用ではない。同じものかを見分けるだけ）。
    public static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data.prefix(65_536) { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(data.count)-\(String(hash, radix: 16))"
    }

    public static func fingerprint(_ file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return UUID().uuidString }   // try?: 読めなければ、毎回違う印（毎回、添える）
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 65_536)) ?? Data()
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? head.count
        return "\(size)-\(fingerprint(head))"
    }
}

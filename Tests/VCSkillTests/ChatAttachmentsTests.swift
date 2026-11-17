import Foundation
import Testing
@testable import VCSkill

/// 会話に添える画像・文章：**添えるかは、利用者の言葉から、コードが決める**。同じものは、2 度、添えない（印）。
@Suite struct ChatAttachmentsTests {
    @Test func imageWordsWinAndTextWordsMeanTheCopiedText() {
        #expect(ChatAttachments.wants("この画像は何？") == .init(image: true, text: false))
        #expect(ChatAttachments.wants("この画面の右上の数字は？") == .init(image: true, text: false))
        #expect(ChatAttachments.wants("スクショについて教えて") == .init(image: true, text: false))
        #expect(ChatAttachments.wants("コピーした画像を要約して") == .init(image: true, text: false))   // 「コピー」は、画像の取り先を決めるだけ
        #expect(ChatAttachments.wants("コピーした文章を要約して") == .init(image: false, text: true))
        #expect(ChatAttachments.wants("クリップボードの内容は？") == .init(image: false, text: true))
        #expect(ChatAttachments.wants("この文章をもっと丁寧にして") == .init(image: false, text: true))
        #expect(ChatAttachments.wants("東京の人口は？") == .init(image: false, text: false))
        #expect(ChatAttachments.wants("") == .init(image: false, text: false))
    }

    @Test func askingToMakeAnImageDoesNotPullInTheCopiedOne() {
        // 利用者の報告：「画像」という言葉だけで、コピーした画像を貼る確認が出ていた
        for request in ["猫の画像を生成して", "青い丸の画像を作って", "ログイン画面を作成して", "背景画像を描いて", "イラストを描いて"] {
            #expect(ChatAttachments.wants(request) == .init(image: false, text: false), "画像は、添えない：\(request)")
        }
        // 手元の画像を指していれば、作る言葉があっても、画像
        for request in ["この画像から、似た画像を作って", "コピーした画像をもとにイラストを描いて", "撮ったスクショを、きれいに作り直して"] {
            #expect(ChatAttachments.wants(request).image, "画像を添える：\(request)")
        }
    }

    @Test func aCopiedTextIsAttachedAndLongOnesAreClipped() throws {
        let short = try #require(ChatAttachments.textAttachment(from: "  こんにちは  "))
        #expect(short.label == "コピーした文章" && short.body == "こんにちは")
        let long = try #require(ChatAttachments.textAttachment(from: String(repeating: "あ", count: ChatAttachments.maxTextCharacters + 500)))
        #expect(long.body.count < ChatAttachments.maxTextCharacters + 60 && long.body.contains("先頭の \(ChatAttachments.maxTextCharacters) 文字だけ"))
        #expect(ChatAttachments.textAttachment(from: "  \n ") == nil)
    }

    @Test func theSameContentHasTheSameKeyAndDifferentContentDiffers() throws {
        #expect(try #require(ChatAttachments.textAttachment(from: "同じ")).key == (try #require(ChatAttachments.textAttachment(from: "同じ"))).key)
        #expect(try #require(ChatAttachments.textAttachment(from: "同じ")).key != (try #require(ChatAttachments.textAttachment(from: "ちがう"))).key)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png"), c = dir.appendingPathComponent("c.png")
        try Data(repeating: 1, count: 500).write(to: a); try Data(repeating: 1, count: 500).write(to: b); try Data(repeating: 2, count: 500).write(to: c)
        #expect(ChatAttachments.fingerprint(a) == ChatAttachments.fingerprint(b))   // 中身が同じなら、同じ印（コピーした画像は、毎回、書き出し直す）
        #expect(ChatAttachments.fingerprint(a) != ChatAttachments.fingerprint(c))
    }

    @Test func composePutsAttachmentsBeforeTheQuestionAndMarksThemAsData() {
        let a = ChatAttachments.Attachment(label: "コピーした文章", body: "本文", key: "k")
        let text = ChatAttachments.compose(question: "要約して", attachments: [a])
        #expect(text == "【添付：コピーした文章】\n本文\n【添付ここまで】\n\n質問：要約して")
        #expect(ChatAttachments.compose(question: "こんにちは", attachments: []) == "こんにちは")
    }
}

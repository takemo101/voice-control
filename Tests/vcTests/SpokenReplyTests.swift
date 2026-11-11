import Testing
@testable import vc

/// 結果の返事を、声で読む文にする：短い「done:」だけ読む。長い文・形が違うものは、読まない。失敗は、短く。
@Suite struct SpokenReplyTests {
    @Test func aShortDoneReplyIsReadWithoutThePrefix() {
        #expect(SpokenReply.success("done: 音量を五十にしました") == "音量を五十にしました")
        #expect(SpokenReply.success("  DONE:  次の曲にしました  ") == "次の曲にしました")
    }

    @Test func longEmptyOrOtherRepliesAreNotRead() {
        #expect(SpokenReply.success("done:") == nil && SpokenReply.success("done:   ") == nil)
        #expect(SpokenReply.success("failed: だめ") == nil && SpokenReply.success("# 見出し\n本文") == nil)
        #expect(SpokenReply.success("done: " + String(repeating: "あ", count: SpokenReply.maxLength + 1)) == nil)
        #expect(SpokenReply.success("done: 一行目\n二行目") == nil)
    }

    @Test func aFailureIsReadBrieflyWithTheFirstSentenceOfTheReason() {
        #expect(SpokenReply.failure("failed: 画像がありません。もう一度撮ってください") == "失敗しました。画像がありません")
        #expect(SpokenReply.failure("") == "失敗しました")
        #expect(SpokenReply.failure(String(repeating: "あ", count: SpokenReply.maxLength + 1)) == "失敗しました")   // 長い理由は、読まない
    }
}

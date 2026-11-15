import Foundation
import Testing
@testable import vc

/// 会話のウィンドウの記録の、状態の移り変わり：中断・失敗した質問が、黙って消えず、理由つきで残る／遅れて届いた知らせが、新しい質問を巻き込まない。
@Suite struct ChatTranscriptTests {
    private func entry(_ question: String) -> ChatEntry { ChatEntry(question: question) }

    @Test func aNewQuestionStopsTheOneStillWaitingAndKeepsItWithTheReason() {
        var entries: [ChatEntry] = []
        let first = entry("調べて")
        entries.begin(first)
        entries.begin(entry("やっぱり、天気は？"))
        #expect(entries.count == 2)                                                // 消さない
        #expect(entries[0].outcome == .stopped("新しい質問を優先しました") && entries[1].isPending)
    }

    @Test func aLateNoticeForAStoppedQuestionDoesNotTouchTheNewOne() {
        var entries: [ChatEntry] = []
        let old = entry("古い質問"), new = entry("新しい質問")
        entries.begin(old); entries.begin(new)
        entries.stop(old.id, reason: "遅れて届いた")                                 // すでに中断済み：変わらない
        entries.finish(old.id, answer: "遅れて届いた答え", rendered: nil, activities: [], notes: [], route: nil, startedNew: false)
        #expect(entries[0].outcome == .stopped("新しい質問を優先しました") && entries[0].answer == nil)   // 答えで、上書きされない
        #expect(entries[1].isPending)                                              // 新しい質問は、そのまま
    }

    @Test func answeringFailingAndStoppingEachLeaveADifferentOutcome() {
        var entries: [ChatEntry] = []
        let a = entry("a"), b = entry("b"), c = entry("c")
        entries.begin(a); entries.finish(a.id, answer: "答え", rendered: nil, activities: [.run("ls")], notes: ["メモ"], route: .local, startedNew: false)
        entries.begin(b); entries.fail(b.id, message: "道具を使えませんでした")
        entries.begin(c); entries.stop(c.id, reason: "取りやめました（Esc）")
        #expect(entries[0].outcome == .answered && entries[0].answer == "答え" && entries[0].activities == [.run("ls")])
        #expect(entries[1].outcome == .failed("道具を使えませんでした") && entries[2].outcome == .stopped("取りやめました（Esc）"))
        #expect(!entries.hasPending)
    }

    @Test func startingANewConversationKeepsOnlyTheCurrentExchange() {
        var entries: [ChatEntry] = []
        let old = entry("昔"), new = entry("いま")
        entries.begin(old); entries.finish(old.id, answer: "答え", rendered: nil, activities: [], notes: [], route: nil, startedNew: false)
        entries.begin(new)
        entries.finish(new.id, answer: "新しい答え", rendered: nil, activities: [], notes: [], route: nil, startedNew: true)   // しばらく話さなかった
        #expect(entries.map(\.question) == ["いま"])
    }

    @Test func aTypedQuestionIsCancelledWhenANewQuestionComes() {
        final class Flag: @unchecked Sendable { var cancelled = false }
        let flag = Flag()
        var typed = entry("文字で送った")
        typed.cancel = { flag.cancelled = true }
        var entries: [ChatEntry] = []
        entries.begin(typed)
        entries.begin(entry("声の質問"))
        #expect(flag.cancelled)                                                    // 処理も、止める（止めた質問を、会話の記録に入れない）
    }
}

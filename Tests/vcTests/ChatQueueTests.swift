import Foundation
import Testing
@testable import vc

/// 会話の順番待ち：文字は、続けて待っていたら、まとめて 1 回。声は、1 件ずつ。「今すぐ送る」は、その 1 件を先頭へ。**文は、テスト用の作り物**。
/// 会話の記録のスクロール：最新（いちばん下）から離れているかの判断（「最新へ」のボタンを出すか）。
@Suite struct ChatScrollTests {
    @Test func theButtonAppearsOnlyWhenScrolledWellAwayFromTheBottom() {
        #expect(!ChatScroll.isAwayFromBottom(contentHeight: 2000, visibleMaxY: 2000))     // いちばん下
        #expect(!ChatScroll.isAwayFromBottom(contentHeight: 2000, visibleMaxY: 1900))     // 少し上（読んでいて、ずれただけ）
        #expect(ChatScroll.isAwayFromBottom(contentHeight: 2000, visibleMaxY: 1700))      // 上へ戻った
        #expect(!ChatScroll.isAwayFromBottom(contentHeight: 400, visibleMaxY: 600))       // 記録が、ウィンドウより短い：スクロールの余地がない
        #expect(!ChatScroll.isAwayFromBottom(contentHeight: 2000, visibleMaxY: 2150))     // 行き過ぎ（バウンス）も、離れていない
        #expect(ChatScroll.isAwayFromBottom(contentHeight: 1000, visibleMaxY: 880.5, threshold: 100))   // 境目：100 を、超えたら
    }
}

@Suite struct ChatQueueTests {
    @Test func typedMessagesThatWaitTogetherAreSentAsOneQuestion() {
        var queue = ChatQueue()
        queue.enqueue("one", source: .typed); queue.enqueue("two", source: .typed)
        let batch = queue.takeNext()
        #expect(batch?.text == "one\n\ntwo" && batch?.source == .typed && batch?.ids.count == 2)
        #expect(queue.isEmpty && queue.takeNext() == nil)
    }

    @Test func aVoiceMessageIsNeverMergedAndKeepsItsPlaceInTheOrder() {
        var queue = ChatQueue()
        queue.enqueue("typed A", source: .typed); queue.enqueue("spoken", source: .voice); queue.enqueue("typed B", source: .typed); queue.enqueue("typed C", source: .typed)
        #expect(queue.takeNext()?.text == "typed A")
        let voice = queue.takeNext()
        #expect(voice?.text == "spoken" && voice?.source == .voice && voice?.ids.count == 1)
        #expect(queue.takeNext()?.text == "typed B\n\ntyped C")
    }

    @Test func sendNowMovesOneMessageToTheFrontAndLeavesTheRestWaiting() {
        var queue = ChatQueue()
        queue.enqueue("first", source: .typed)
        let urgent = queue.enqueue("urgent", source: .typed)
        queue.enqueue("last", source: .voice)
        queue.moveToFront(urgent.id)
        #expect(queue.items.map(\.text) == ["urgent", "first", "last"])
        queue.moveToFront(UUID())   // 知らない件は、何もしない
        #expect(queue.items.map(\.text) == ["urgent", "first", "last"])
        #expect(queue.takeNext()?.text == "urgent")   // 先頭へ出した 1 件は、ほかの文字と、まとめない
        #expect(queue.takeNext()?.text == "first")
    }

    @Test func aWithdrawnMessageIsReturnedAndTheRestIsKept() {
        var queue = ChatQueue()
        let first = queue.enqueue("keep", source: .typed), second = queue.enqueue("withdraw", source: .voice)
        #expect(queue.remove(second.id)?.text == "withdraw" && queue.remove(second.id) == nil)
        #expect(queue.items.map(\.id) == [first.id])
        #expect(queue.removeAll().map(\.text) == ["keep"] && queue.isEmpty)
    }
}

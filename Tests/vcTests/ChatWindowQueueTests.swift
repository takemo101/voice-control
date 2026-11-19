import Foundation
import Testing
@testable import vc

/// 会話ウィンドウの順番待ち（画面を出さずに、状態の移り変わりだけを確かめる）。`ChatWindow.shared` は 1 つなので、直列で動かして、毎回、片付ける。**文は、作り物**。
@Suite(.serialized) @MainActor struct ChatWindowQueueTests {
    private final class Started { var texts: [String] = [] }

    private func begin(_ window: ChatWindow, _ text: String, cancel: (() -> Void)? = nil) -> UUID {
        window.begin(question: text, agent: "test", warning: nil, tools: nil, cancel: cancel)
    }

    @Test func aMessageSentWhileThinkingWaitsAndThenStartsOnceTheAnswerArrives() {
        let window = ChatWindow.shared; window.clear(); defer { window.clear(); window.startTyped = nil }
        let started = Started(); window.startTyped = { started.texts.append($0) }
        window.submitTyped("first")
        #expect(started.texts == ["first"] && window.isBusy)            // 考えていなければ、すぐ始める（`begin` までの間も、考えている扱い）
        let id = begin(window, "first")
        window.submitTyped("second"); window.submitTyped("third")
        #expect(started.texts == ["first"] && window.queuedTexts == ["second", "third"])   // 考えている間は、待つ
        window.finish(id, answer: "done", activities: [], notes: [], startedNew: false)
        #expect(started.texts == ["first", "second\n\nthird"] && window.queuedTexts.isEmpty)   // 終わったら、まとめて 1 回
    }

    @Test func stoppingByTheUserDropsTheQueueButBeingSupersededDoesNot() {
        let window = ChatWindow.shared; window.clear(); defer { window.clear(); window.startTyped = nil }
        let started = Started(); window.startTyped = { started.texts.append($0) }
        window.submitTyped("a"); let a = begin(window, "a")
        window.submitTyped("b")
        window.stop(a, reason: "x", dropsQueue: true)                    // Esc・停止
        #expect(started.texts == ["a"] && window.queuedTexts.isEmpty && !window.isBusy)   // 待っていた分は、送らない
        window.submitTyped("c"); let c = begin(window, "c")
        window.submitTyped("d")
        window.stop(c, reason: "x")                                      // 取って代わられた：待っていた分は、続ける
        #expect(started.texts == ["a", "c", "d"])
    }

    @Test func sendNowStopsTheCurrentQuestionAndStartsOnlyThatMessageFirst() {
        let window = ChatWindow.shared; window.clear(); defer { window.clear(); window.startTyped = nil }
        let started = Started(); window.startTyped = { started.texts.append($0) }
        window.submitTyped("running")
        var cancelled = false
        let running = begin(window, "running") { cancelled = true }
        window.submitTyped("later"); window.submitTyped("urgent")
        // 「今すぐ送る」は、画面のボタン経由（`state.sendNow`）。ここでは、同じ結果を、取りやめの手続きで確かめる
        window.sendNowForTesting(window.queuedTexts.firstIndex(of: "urgent")!)
        #expect(cancelled)
        window.stop(running, reason: "新しい質問を優先しました")
        #expect(started.texts == ["running", "urgent"] && window.queuedTexts == ["later"])   // その 1 件だけ（残りと、まとめない）
    }

    @Test func aSpokenQuestionWaitsForItsTurnAndCanBeCancelled() async {
        let window = ChatWindow.shared; window.clear(); defer { window.clear(); window.startTyped = nil }
        window.startTyped = { _ in }
        window.submitTyped("typed"); let typed = begin(window, "typed")
        let first = Task { @MainActor in await window.waitForTurn("spoken one") }
        let second = Task { @MainActor in await window.waitForTurn("spoken two") }
        await Task.yield(); await Task.yield()
        #expect(window.queuedTexts == ["spoken one", "spoken two"])
        second.cancel()
        #expect(await second.value == false && window.queuedTexts == ["spoken one"])   // 取りやめ：順番待ちから、外れる
        window.finish(typed, answer: "done", activities: [], notes: [], startedNew: false)
        #expect(await first.value == true)                                              // 順番が来た
        #expect(window.isBusy)                                                          // 始める予約（`begin` まで、ほかの質問を、割り込ませない）
        window.releaseStart()
        #expect(!window.isBusy)
    }
}

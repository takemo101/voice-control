import Foundation
import Testing
@testable import vc

/// 会話ウィンドウの順番待ち（画面を出さずに、状態の移り変わりだけを確かめる）。`ChatWindow.shared` は 1 つなので、直列で動かして、毎回、片付ける。**文は、作り物**。
/// 確かめるのは、実際に起きた（または、起きうる）タイミングの不具合：始める予約の取りこぼし・順番の入れ替わり・取りやめのあとの動き出し。
/// `ChatWindow.shared` を使うテストは、**スイートをまたいで、直列**にする（並行に動くと、お互いの状態を、壊す）：この入れ物の中に、置く。
@Suite(.serialized) enum SharedChatWindow {}

extension SharedChatWindow {
@Suite @MainActor struct QueueStateTests {
    private final class Started { var texts: [String] = []; var fileNames: [[String]] = [] }

    /// 毎回、まっさらにして、終わりに、片付ける。
    private func fresh() -> (ChatWindow, Started) {
        let window = ChatWindow.shared
        window.clear()
        window.reservationTimeout = .seconds(15)
        let started = Started()
        window.startTyped = { text, files in started.texts.append(text); started.fileNames.append(files.map(\.name)) }
        window.injectSpoken = nil
        window.interruptVoiceTurn = nil
        return (window, started)
    }

    private func tearDown(_ window: ChatWindow) {
        window.clear()
        window.startTyped = nil; window.injectSpoken = nil; window.interruptVoiceTurn = nil
        window.reservationTimeout = .seconds(15)
    }

    private func begin(_ window: ChatWindow, _ text: String, cancel: (() -> Void)? = nil) -> UUID {
        window.begin(question: text, agent: "test", warning: nil, tools: nil, cancel: cancel)
    }

    private func finish(_ window: ChatWindow, _ id: UUID) {
        window.finish(id, answer: "done", activities: [], notes: [], startedNew: false)
    }

    // MARK: 文字

    @Test func aMessageSentWhileThinkingWaitsAndThenStartsOnceTheAnswerArrives() {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.submitTyped("first")
        #expect(started.texts == ["first"] && window.isBusy)            // 考えていなければ、すぐ始める（`begin` までの間も、考えている扱い）
        let id = begin(window, "first")
        window.submitTyped("second"); window.submitTyped("third")
        #expect(started.texts == ["first"] && window.queuedTexts == ["second", "third"])   // 考えている間は、待つ
        finish(window, id)
        #expect(started.texts == ["first", "second\n\nthird"] && window.queuedTexts.isEmpty)   // 終わったら、まとめて 1 回
    }

    @Test func aFailedQuestionStillLetsTheQueueContinue() {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.submitTyped("a"); let a = begin(window, "a")
        window.submitTyped("b")
        window.fail(a, message: "boom")
        #expect(started.texts == ["a", "b"])                             // 失敗は、待っていた質問を、巻き込まない
    }

    @Test func stoppingByTheUserDropsTheQueueButBeingSupersededDoesNot() {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.submitTyped("a"); let a = begin(window, "a")
        window.submitTyped("b")
        window.stop(a, reason: "x", dropsQueue: true)                    // Esc・停止
        #expect(started.texts == ["a"] && window.queuedTexts.isEmpty && !window.isBusy)   // 待っていた分は、送らない
        #expect(window.transcript.last?.question == "b" && window.transcript.last?.outcome == .stopped("送られませんでした（停止）"))   // 消さずに、理由つきで残す
        window.submitTyped("c"); let c = begin(window, "c")
        window.submitTyped("d")
        window.stop(c, reason: "x")                                      // 取って代わられた：待っていた分は、続ける
        #expect(started.texts == ["a", "c", "d"])
    }

    @Test func theStopButtonStopsTheCurrentQuestionDropsTheQueueAndDoesNotLeakIntoTheNextTurn() {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.submitTyped("running")
        var cancelled = 0
        let running = begin(window, "running") { cancelled += 1 }
        window.submitTyped("later")
        window.stopCurrent()
        #expect(cancelled == 1)
        window.stop(running, reason: "新しい質問を優先しました")           // 取りやめの手続きが、返ってくる（理由は、停止に、置き換わる）
        #expect(window.transcript.first?.outcome == .stopped("取りやめました（停止）"))
        #expect(started.texts == ["running"] && window.queuedTexts.isEmpty)
        window.submitTyped("next"); let next = begin(window, "next")     // 停止の印が、次の質問に、残らない
        window.submitTyped("after")
        window.stop(next, reason: "x")
        #expect(started.texts == ["running", "next", "after"])           // 次の取って代わりでは、待っている分は、続く
        let after = begin(window, "after"); finish(window, after)
        window.stopCurrent()                                             // 考えていなければ、何もしない（印も、残さない）
        window.submitTyped("last"); let last = begin(window, "last")
        window.submitTyped("kept")
        window.stop(last, reason: "x")
        #expect(started.texts == ["running", "next", "after", "last", "kept"])
    }

    @Test func sendNowStopsTheCurrentQuestionAndStartsOnlyThatMessageFirst() {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.submitTyped("running")
        var cancelled = false
        let running = begin(window, "running") { cancelled = true }
        window.submitTyped("later"); window.submitTyped("urgent")
        window.sendNow(window.queued.first { $0.text == "urgent" }!.id)
        #expect(cancelled)
        window.stop(running, reason: "新しい質問を優先しました")
        #expect(started.texts == ["running", "urgent"] && window.queuedTexts == ["later"])   // その 1 件だけ（残りと、まとめない）
    }

    @Test func sendNowWhileNothingIsRunningJustStartsIt() {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.submitTyped("a"); let a = begin(window, "a")
        window.submitTyped("b")
        let id = window.queued[0].id
        finish(window, a)                                                // b は、もう始まっている
        window.sendNow(id)                                               // 古いボタン：何も起きない
        #expect(started.texts == ["a", "b"] && window.queuedTexts.isEmpty)
    }

    @Test func removingAQueuedMessageGivesItBackToTheEmptyInputOnly() {
        let (window, _) = fresh(); defer { tearDown(window) }
        window.submitTyped("running"); _ = begin(window, "running")
        window.submitTyped("one"); window.submitTyped("two")
        window.removeQueued(window.queued[0].id)
        #expect(window.draftText == "one" && window.queuedTexts == ["two"])
        window.removeQueued(window.queued[0].id)
        #expect(window.draftText == "one" && window.queuedTexts.isEmpty)   // 入力欄に、書きかけがあれば、上書きしない
        window.removeQueued(UUID())                                        // 知らない件は、何もしない
    }

    @Test func resetWhileThinkingCancelsTheRunningQuestionAndForgetsTheQueue() {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.submitTyped("running")
        var cancelled = false
        let running = begin(window, "running") { cancelled = true }
        window.submitTyped("later")
        window.clear()                                                   // 新しい会話
        #expect(cancelled && window.transcript.isEmpty && window.queuedTexts.isEmpty && !window.isBusy)
        finish(window, running)                                          // 遅れて届いた答え：何も、動かさない
        #expect(started.texts == ["running"] && window.transcript.isEmpty)
    }

    // MARK: 声

    @Test func aSpokenQuestionIsClaimedAtOnceWhenIdleAndQueuedWithoutWaitingWhenBusy() {
        let (window, _) = fresh(); defer { tearDown(window) }
        #expect(window.claimTurn("spoken one") && window.isBusy)         // 始める予約を持つ
        #expect(window.claimTurn("spoken two") == false)                 // 予約の間も、割り込ませない：順番待ちへ（待たずに、戻る）
        #expect(window.queued.map(\.source) == [.voice] && window.queuedTexts == ["spoken two"])
        window.releaseStart()                                            // 始められなかった：外して、次へ（戻す先がない：記録に残す）
        #expect(window.transcript.last?.outcome == .stopped("送られませんでした（声の流れが止まっています）") && !window.isBusy)
    }

    @Test func aQueuedSpokenQuestionIsHandedBackToTheVoiceFlowAndPassesItsOwnClaim() {
        let (window, _) = fresh(); defer { tearDown(window) }
        let injected = Started(); window.injectSpoken = { injected.texts.append($0); return true }
        window.submitTyped("running"); let running = begin(window, "running")
        window.enqueueSpoken("spoken ahead")
        #expect(window.queuedTexts == ["spoken ahead"] && injected.texts.isEmpty)       // 考えている間は、待つ
        finish(window, running)
        #expect(injected.texts == ["spoken ahead"] && window.queuedTexts.isEmpty && window.isBusy)   // 順番が来た：声の流れへ戻す（予約を持つ）
        #expect(window.claimTurn("another") == false)                                    // 戻っている間に来た、別の発話は、割り込まない
        #expect(window.claimTurn("spoken ahead") == true)                                // 戻ってきた発話は、通る
        #expect(window.claimTurn("spoken ahead") == false)                               // 通れるのは、1 度だけ
    }

    @Test func orderIsKeptAcrossTypedAndSpokenQuestions() {
        let (window, started) = fresh(); defer { tearDown(window) }
        let injected = Started(); window.injectSpoken = { injected.texts.append($0); return true }
        window.submitTyped("t1"); let t1 = begin(window, "t1")
        window.enqueueSpoken("voice")
        window.submitTyped("t2")
        finish(window, t1)
        #expect(injected.texts == ["voice"] && started.texts == ["t1"])                  // 声が先（t2 は、声の次）：t2 は、声が終わるまで、始まらない
        #expect(window.claimTurn("voice")); let voice = begin(window, "voice")
        #expect(started.texts == ["t1"] && window.queuedTexts == ["t2"])
        finish(window, voice)
        #expect(started.texts == ["t1", "t2"])
    }

    @Test func aReturnedUtteranceThatNeverBecomesAQuestionDoesNotBlockTheNextOne() {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.injectSpoken = { _ in true }
        window.submitTyped("t1"); let t1 = begin(window, "t1")
        window.enqueueSpoken("会話を終わりにして"); window.submitTyped("t2")
        finish(window, t1)
        #expect(window.isBusy && started.texts == ["t1"])
        window.dropInjection("会話を終わりにして")                                          // 質問にならずに、終わった
        #expect(started.texts == ["t1", "t2"])                                           // 次へ進む
        window.dropInjection("会話を終わりにして")                                          // 戻った発話でなければ、何もしない
        #expect(started.texts == ["t1", "t2"])
    }

    @Test func aReservationThatNeverBecomesAQuestionIsReleasedAndTheNextOneStarts() async {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.reservationTimeout = .milliseconds(40)
        window.injectSpoken = { _ in true }                                                   // 戻した発話を、誰も、受け取らない（声の流れが作り直された）
        window.submitTyped("t1"); let t1 = begin(window, "t1")
        window.enqueueSpoken("lost"); window.submitTyped("t2")
        finish(window, t1)
        #expect(window.isBusy && started.texts == ["t1"])
        for _ in 0..<100 where started.texts.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(started.texts == ["t1", "t2"])                                           // 予約が外れて、次の質問が動いた
        #expect(window.claimTurn("lost") == false)                                       // 失った発話は、通れない（次の質問の予約の間は、順番待ちへ）
    }

    @Test func aSpokenQuestionWithNowhereToGoIsKeptWithTheReason() {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.submitTyped("t1"); let t1 = begin(window, "t1")
        window.enqueueSpoken("orphan"); window.submitTyped("t2")
        finish(window, t1)                                                               // 声の流れが、ない：消さずに、残して、次へ
        #expect(window.transcript.contains { $0.question == "orphan" && $0.outcome == .stopped("送られませんでした（声の流れが止まっています）") })
        #expect(started.texts == ["t1", "t2"])
    }

    @Test func aStoppedVoiceFlowThatRefusesTheUtteranceIsHandledLikeNowhereToGo() {
        let (window, started) = fresh(); defer { tearDown(window) }
        window.injectSpoken = { _ in false }                                             // 声の流れが、止まっている
        window.submitTyped("t1"); let t1 = begin(window, "t1")
        window.enqueueSpoken("orphan"); window.submitTyped("t2")
        finish(window, t1)
        #expect(window.transcript.contains { $0.question == "orphan" && $0.outcome == .stopped("送られませんでした（声の流れが止まっています）") })
        #expect(started.texts == ["t1", "t2"] && window.claimTurn("orphan") == false)    // 予約は、残らない（次の質問が、動いている）
    }

    // MARK: 添えるファイル

    private func sampleFiles(_ names: [String]) throws -> (dir: URL, urls: [URL]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-queue-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = try names.map { name -> URL in
            let url = dir.appendingPathComponent(name)
            try Data("見本 \(name)".utf8).write(to: url)
            return url
        }
        return (dir, urls)
    }

    @Test func attachedFilesTravelWithTheTypedQuestionAndDoNotStickToTheNextOne() throws {
        let (window, started) = fresh(); defer { tearDown(window) }
        let sample = try sampleFiles(["a.txt", "b.txt", "c.txt"]); defer { try? FileManager.default.removeItem(at: sample.dir) }
        window.addFiles([sample.urls[0]])
        window.submitTyped("first")                                   // 考えていない：すぐ始まる。ファイルは、この質問のもの
        let t1 = begin(window, "first")
        #expect(window.attachedFiles.isEmpty)                          // 札は、空になる（次の質問に、付かない）
        window.addFiles([sample.urls[1]]); window.submitTyped("second")
        window.addFiles([sample.urls[2]]); window.submitTyped("third")  // 順番待ちで、まとめられる質問の、ファイルも、まとまる
        finish(window, t1)
        #expect(started.texts == ["first", "second\n\nthird"])
        #expect(started.fileNames == [["a.txt"], ["b.txt", "c.txt"]])
        #expect(window.attachedFiles.isEmpty)
    }

    @Test func takingAQueuedQuestionBackReturnsItsFilesToTheComposer() throws {
        let (window, _) = fresh(); defer { tearDown(window) }
        let sample = try sampleFiles(["a.txt"]); defer { try? FileManager.default.removeItem(at: sample.dir) }
        window.submitTyped("busy"); _ = begin(window, "busy")
        window.addFiles([sample.urls[0]]); window.submitTyped("queued")
        guard let item = window.queued.first else { Issue.record("順番待ちが空"); return }
        window.removeQueued(item.id)
        #expect(window.attachedFiles.map(\.name) == ["a.txt"])         // 外した質問の、ファイルは、入力欄へ戻る
    }

    @Test func secretFilesAreRefusedWithAVisibleReasonAndTheRestIsAttached() throws {
        let (window, _) = fresh(); defer { tearDown(window) }
        let sample = try sampleFiles(["ok.txt", ".env"]); defer { try? FileManager.default.removeItem(at: sample.dir) }
        window.addFiles(sample.urls)
        #expect(window.attachedFiles.map(\.name) == ["ok.txt"])
        #expect(window.fileNoticeText?.contains(".env") == true)
        window.clear()
        #expect(window.attachedFiles.isEmpty && window.fileNoticeText == nil)   // 会話を消すと、札も消える
    }
}
}

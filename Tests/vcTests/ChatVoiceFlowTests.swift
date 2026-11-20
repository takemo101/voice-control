import Foundation
import Testing
import VCCore
import VCSkill
@testable import VCSpeech
@testable import vc

/// 会話の**声の流れ**と**会話ウィンドウの順番待ち**を、つないで確かめる（マイク・画面・言語モデルは、偽物）。
/// 実際に起きた不具合の通し：声に声が続いたとき・考えている間に話したとき・Esc・認識中に続けて話したとき。
/// 偽の処理は、`ChatVoice.handle` と同じ手順で、ウィンドウを使う（`claimTurn` → `begin` → 答え／取りやめ）。**文は、作り物**。
extension SharedChatWindow {
@Suite @MainActor struct VoiceFlowTests {
    // MARK: 偽物

    @MainActor final class Trigger: PushToTalkTrigger {
        var onPress: (@Sendable () -> Void)?
        var onRelease: (@Sendable () -> Void)?
    }

    @MainActor final class Escape: EscapeSource {
        var onEscape: (@Sendable () -> Void)?
        func setActive(_ active: Bool) -> Bool { true }
    }

    final class Recorder: Recording, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [URL] = []
        func enqueue(_ url: URL) { lock.lock(); results.append(url); lock.unlock() }
        func start() {}
        func discard() {}
        func stop() throws -> URL? { lock.lock(); defer { lock.unlock() }; return results.isEmpty ? nil : results.removeFirst() }
    }

    /// 開くまで、待つ（認識・答えを、テストが決めた時点まで止める）。
    final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func open() { lock.lock(); on = true; lock.unlock() }
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }

    final class Transcriber: Transcribing, @unchecked Sendable {
        private let lock = NSLock()
        private var holds: [String: Switch] = [:]
        private var started: [String] = []
        func hold(_ name: String, _ gate: Switch) { lock.lock(); holds[name] = gate; lock.unlock() }
        /// 認識が始まったファイル（順に）。
        var entered: [String] { lock.lock(); defer { lock.unlock() }; return started }
        func transcribe(file url: URL) async throws -> String {
            lock.lock(); let gate = holds[url.lastPathComponent]; started.append(url.lastPathComponent); lock.unlock()
            while let gate, !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) }
            let name = url.lastPathComponent
            return name.hasPrefix("say-") ? String(name.dropFirst(4)) : "text-" + name   // `say-<文>`：その文が、そのまま、認識される
        }
    }

    /// 起きたこと（順に）と、同時に動いた数。
    final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        private var inFlight = 0
        private(set) var maxInFlight = 0
        func add(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
        func enter() { lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock() }
        func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
        func list() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
        func starts() -> [String] { list().filter { $0.hasPrefix("start:") } }
    }

    /// 会話の組み立て（`VoiceSession` と同じ配線）。
    @MainActor final class Rig {
        let window = ChatWindow.shared
        let trigger = Trigger(), escape = Escape(), recorder = Recorder(), transcriber = Transcriber()
        let journal = Journal()
        private var gates: [String: Switch] = [:]
        var loop: VoiceLoop!

        init() {
            window.clear()
            window.reservationTimeout = .seconds(15)
            loop = VoiceLoop(trigger: trigger, escape: escape, recorder: recorder, transcriber: transcriber,
                             handler: { [unowned self] text, token, _, _ in await handle(text, token: token, fromQueue: false) }, onEvent: { _, _ in })
            loop.keepsRunning = { _, _ in true }   // 偽の流れは、会話だけ
            loop.onDeferred = { text, _ in
                Task { @MainActor in
                    guard !text.isEmpty else { return }
                    if ChatStopCommand.matches(text) { ChatWindow.shared.stopAll(); return }   // `VoiceSession` と同じ
                    ChatWindow.shared.enqueueSpoken(text)
                }
            }
            let loop = self.loop!
            window.injectSpoken = { loop.inject($0, tag: "") }
            window.interruptVoiceTurn = { loop.interruptRunning() }
            window.startTyped = { [unowned self] text in Task { @MainActor in await handle(text, token: CancelToken(), fromQueue: true) } }
            loop.begin(onReady: {})
        }

        func tearDown() {
            loop.stop()
            window.clear()
            window.startTyped = nil; window.injectSpoken = nil; window.interruptVoiceTurn = nil
        }

        /// 答えが出るのを、止めておく／出す。
        func gate(_ text: String) -> Switch {
            if let existing = gates[text] { return existing }
            let new = Switch(); gates[text] = new; return new
        }

        /// 声で話す（押して、離す）。文字になると "text-<name>"。
        func speak(_ name: String) {
            recorder.enqueue(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name))
            trigger.onPress?()
            trigger.onRelease?()
        }

        /// `ChatVoice.handle` と同じ手順の、偽の処理。
        func handle(_ text: String, token: CancelToken, fromQueue: Bool) async {
            if !fromQueue, ChatStopCommand.matches(text) { window.stopAll(); journal.add("stop:" + text); return }   // `ChatVoice.handle` と同じ
            if !fromQueue, !window.claimTurn(text) { journal.add("queued:" + text); return }
            if token.isCancelled || token.isSuperseded { window.releaseStart(); return }
            let id = window.begin(question: text, agent: "test", warning: nil, tools: nil, cancel: fromQueue ? { token.supersede() } : nil)
            journal.add("start:" + text); journal.enter()
            defer { journal.leave() }
            let gate = self.gate(text)
            while !gate.isOpen && !token.isCancelled && !token.isSuperseded { try? await Task.sleep(for: .milliseconds(5)) }
            if token.isSuperseded { window.stop(id, reason: "superseded"); journal.add("superseded:" + text); return }
            if token.isCancelled { window.stop(id, reason: "esc", dropsQueue: true); journal.add("cancelled:" + text); return }
            window.finish(id, answer: "ok", activities: [], notes: [], startedNew: false)
            journal.add("done:" + text)
        }
    }

    /// 条件が満たされるまで待つ（上限 5 秒）。
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: 通し

    @Test func continuousSpeechQueuesVisiblyAndRunsInOrderOneAtATime() async {
        let rig = Rig(); defer { rig.tearDown() }
        rig.speak("a1")
        #expect(await eventually { rig.journal.starts() == ["start:text-a1"] })
        rig.speak("a2"); rig.speak("a3")                                               // 考えている間に、続けて話す
        #expect(await eventually { rig.window.queuedTexts == ["text-a2", "text-a3"] }) // 見える順番待ち（取りやめられていない）
        #expect(rig.journal.list().contains { $0.hasPrefix("cancelled") || $0.hasPrefix("superseded") } == false)
        rig.gate("text-a1").open()
        #expect(await eventually { rig.journal.starts() == ["start:text-a1", "start:text-a2"] })   // 1 つ終わると、次が始まる
        #expect(rig.window.queuedTexts == ["text-a3"])
        rig.gate("text-a2").open()
        #expect(await eventually { rig.journal.starts().count == 3 })
        rig.gate("text-a3").open()
        #expect(await eventually { rig.journal.list().last == "done:text-a3" })
        #expect(rig.journal.starts() == ["start:text-a1", "start:text-a2", "start:text-a3"] && rig.journal.maxInFlight == 1)   // 順番どおり・同時には動かない
        #expect(await eventually { !rig.window.isBusy })
    }

    @Test func escWhileThinkingStopsItAndDropsWhatWasWaiting() async {
        let rig = Rig(); defer { rig.tearDown() }
        rig.speak("a1")
        #expect(await eventually { rig.journal.starts().count == 1 })
        rig.speak("a2"); rig.speak("a3")
        #expect(await eventually { rig.window.queuedTexts.count == 2 })
        rig.escape.onEscape?()
        #expect(await eventually { rig.journal.list().contains("cancelled:text-a1") })
        #expect(await eventually { rig.window.queuedTexts.isEmpty && !rig.window.isBusy })
        #expect(rig.window.transcript.filter { $0.outcome == .stopped("送られませんでした（停止）") }.map(\.question) == ["text-a2", "text-a3"])   // 消さずに、残る
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.journal.starts() == ["start:text-a1"])                              // 取りやめのあと、動き出さない
    }

    @Test func speakingWhileTheFirstOneIsStillBeingRecognizedKeepsTheOrder() async {
        let rig = Rig(); defer { rig.tearDown() }
        let hold = Switch()
        rig.transcriber.hold("b1", hold)                                               // 最初の発話は、まだ認識中
        rig.speak("b1")
        #expect(await eventually { rig.transcriber.entered == ["b1"] })                // 最初の発話の認識が、始まっている（処理は、認識の段階）
        rig.speak("b2")                                                                // 認識中に、続けて話す：入れ替わらない・取りやめない
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.journal.starts().isEmpty && rig.window.queuedTexts.isEmpty)
        hold.open()
        #expect(await eventually { rig.journal.starts() == ["start:text-b1"] })
        rig.gate("text-b1").open()
        #expect(await eventually { rig.journal.starts() == ["start:text-b1", "start:text-b2"] })
        #expect(rig.journal.list().contains { $0.hasPrefix("cancelled") || $0.hasPrefix("superseded") } == false)
        rig.gate("text-b2").open()
        #expect(await eventually { rig.journal.list().last == "done:text-b2" })
    }

    @Test func spokenQuestionsDuringATypedQuestionQueueWithoutBlockingTheVoiceFlow() async {
        let rig = Rig(); defer { rig.tearDown() }
        rig.window.submitTyped("t1")
        #expect(await eventually { rig.journal.starts() == ["start:t1"] })
        rig.speak("v1")
        #expect(await eventually { rig.journal.list().contains("queued:text-v1") })    // 声の流れは、すぐ戻る
        rig.speak("v2")
        #expect(await eventually { rig.journal.list().contains("queued:text-v2") })    // 塞がっていない：続けて、受けられる
        #expect(rig.window.queuedTexts == ["text-v1", "text-v2"])
        rig.gate("t1").open()
        #expect(await eventually { rig.journal.starts() == ["start:t1", "start:text-v1"] })
        rig.gate("text-v1").open()
        #expect(await eventually { rig.journal.starts().count == 3 })
        #expect(rig.journal.starts() == ["start:t1", "start:text-v1", "start:text-v2"])
        rig.gate("text-v2").open()
        #expect(await eventually { !rig.window.isBusy })
        #expect(rig.journal.maxInFlight == 1)
    }

    @Test func aTypedMessageWaitingBehindASpokenOneRunsAfterIt() async {
        let rig = Rig(); defer { rig.tearDown() }
        rig.speak("a1")
        #expect(await eventually { rig.journal.starts().count == 1 })
        rig.speak("a2")
        #expect(await eventually { rig.window.queuedTexts == ["text-a2"] })
        rig.window.submitTyped("t")                                                    // 声の次
        rig.gate("text-a1").open()
        #expect(await eventually { rig.journal.starts() == ["start:text-a1", "start:text-a2"] })   // 声が先
        rig.gate("text-a2").open()
        #expect(await eventually { rig.journal.starts().count == 3 })
        #expect(rig.journal.starts().last == "start:t")
        rig.gate("t").open()
        #expect(await eventually { !rig.window.isBusy })
        #expect(rig.journal.maxInFlight == 1)
    }

    @Test func sendNowOnASpokenMessageStopsTheCurrentOneAndRunsThatMessageFirst() async {
        let rig = Rig(); defer { rig.tearDown() }
        rig.speak("a1")
        #expect(await eventually { rig.journal.starts().count == 1 })
        rig.speak("a2"); rig.speak("a3")
        #expect(await eventually { rig.window.queuedTexts == ["text-a2", "text-a3"] })
        rig.window.sendNow(rig.window.queued[1].id)                                    // a3 を、今すぐ
        #expect(await eventually { rig.journal.list().contains("superseded:text-a1") })
        #expect(await eventually { rig.journal.starts() == ["start:text-a1", "start:text-a3"] })   // a3 が先
        #expect(rig.window.queuedTexts == ["text-a2"])                                 // 残りは、そのあと
        rig.gate("text-a3").open()
        #expect(await eventually { rig.journal.starts().count == 3 })
        #expect(rig.journal.starts().last == "start:text-a2")
    }

    @Test func theStopButtonStopsASpokenQuestionAndDropsTheQueue() async {
        let rig = Rig(); defer { rig.tearDown() }
        rig.speak("a1")
        #expect(await eventually { rig.journal.starts().count == 1 })
        rig.speak("a2")
        #expect(await eventually { rig.window.queuedTexts == ["text-a2"] })
        rig.window.stopCurrent()
        #expect(await eventually { rig.window.queuedTexts.isEmpty && !rig.window.isBusy })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.journal.starts() == ["start:text-a1"])
        #expect(rig.window.transcript.contains { $0.question == "text-a2" && $0.outcome == .stopped("送られませんでした（停止）") })
    }

    @Test func aSpokenStopWordStopsThinkingAndDropsTheQueueWithoutBeingQueuedItself() async {
        let rig = Rig(); defer { rig.tearDown() }
        rig.speak("a1")
        #expect(await eventually { rig.journal.starts().count == 1 })
        rig.speak("a2")
        #expect(await eventually { rig.window.queuedTexts == ["text-a2"] })
        rig.speak("say-止めて")                                                          // 考えている間に、「止めて」
        #expect(await eventually { rig.journal.list().contains { $0.hasPrefix("superseded:") || $0.hasPrefix("cancelled:") } })
        #expect(await eventually { rig.window.queuedTexts.isEmpty && !rig.window.isBusy })
        #expect(rig.window.transcript.contains { $0.question == "text-a2" && $0.outcome == .stopped("送られませんでした（停止）") })
        #expect(rig.window.transcript.contains { $0.question == "止めて" } == false)      // 「止めて」は、質問として、残らない
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.journal.starts() == ["start:text-a1"])                              // 止めたあとに、何も動き出さない
    }

    @Test func aSpokenStopWordAlsoStopsATypedQuestionAndItsQueue() async {
        let rig = Rig(); defer { rig.tearDown() }
        rig.window.submitTyped("t1")
        #expect(await eventually { rig.journal.starts() == ["start:t1"] })
        rig.window.submitTyped("t2")
        rig.speak("say-stop")                                                           // 声の流れは、塞がっていない：すぐ、受けて、止める
        #expect(await eventually { rig.journal.list().contains("stop:stop") })
        #expect(await eventually { rig.window.queuedTexts.isEmpty && !rig.window.isBusy })
        #expect(rig.journal.starts() == ["start:t1"])
    }

    @Test func aLongSentenceWithAStopWordInsideIsQueuedAsAnOrdinaryQuestion() async {
        let rig = Rig(); defer { rig.tearDown() }
        rig.speak("a1")
        #expect(await eventually { rig.journal.starts().count == 1 })
        rig.speak("say-音楽を止めて")
        #expect(await eventually { rig.window.queuedTexts == ["音楽を止めて"] })          // 止めない：普通の質問として、順番待ち
        #expect(rig.journal.list().contains { $0.hasPrefix("cancelled") || $0.hasPrefix("superseded") } == false)
    }

    @Test func aStopWordWithNothingToStopChangesNothing() async {
        let rig = Rig(); defer { rig.tearDown() }
        rig.speak("say-ストップ")
        #expect(await eventually { rig.journal.list().contains("stop:ストップ") })
        #expect(!rig.window.isBusy && rig.window.queuedTexts.isEmpty && rig.window.transcript.isEmpty)
    }
}
}

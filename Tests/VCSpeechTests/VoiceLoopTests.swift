import Foundation
import Testing
@testable import VCSpeech
import VCCore

// `VoiceLoop`（声の流れの調整）の単体テスト。マイク・音声認識・Carbon のホットキーは使わず、録音・文字起こし・トリガー・Esc を偽物に差し替える（偽物は `VoiceLoopFakes.swift`）。
// 待つのは、継続（`Mailbox`・`Gate`）だけ（スリープで待たない）。

@MainActor @Suite(.timeLimit(.minutes(1))) struct VoiceLoopTests {
    @Test func utteranceReachesTheHandlerAndTheTemporaryFileIsRemoved() async throws {
        let handled = Mailbox<String>()
        let fileGone = Mailbox<Bool>()
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vc-loop-\(UUID().uuidString).caf")
        try Data("x".utf8).write(to: file)
        let h = Harness { utterance, token, _, _ in
            handled.put(utterance + (token.isCancelled ? "(cancelled)" : ""))
            fileGone.put(!FileManager.default.fileExists(atPath: file.path))
        }
        h.recorder.enqueue(.success(file))
        h.trigger.onPress?()
        h.trigger.onRelease?()
        #expect(await handled.take() == "text-\(file.lastPathComponent)")
        #expect(await fileGone.take())   // 認識したあと、ハンドラが呼ばれる前に、消えている
        #expect(h.recorder.starts == 1 && h.recorder.stops == 1 && h.recorder.discards == 0)
        #expect(h.log.labels == ["recordingStarted", "recognizing", "recognized:text-\(file.lastPathComponent)"])
    }

    @Test func escWhileRecognizingCancelsAndTheNextUtteranceIsHandledNormally() async {
        let handled = Mailbox<String>()
        let calls = Counter()
        let h = Harness { utterance, token, _, _ in
            _ = calls.next()
            handled.put(utterance + (token.isCancelled ? "(cancelled)" : ""))
        }
        let gate = Gate()
        h.transcriber.hold("a1", gate)
        h.speak("a1")
        #expect(await h.transcriber.entered.take() == "a1")   // 認識中
        h.escapeKey()
        #expect(h.log.labels.contains("cancelling"))
        gate.open()
        await h.log.wait(for: "recognitionCancelled")          // ハンドラには届かず、取りやめが知らされる
        #expect(!h.log.labels.contains("recognized:text-a1"))

        h.speak("a2")   // 取りやめの合図（.cancel）が列に残っていても、次の発話は、取りやめられない
        #expect(await handled.take() == "text-a2")
        #expect(h.log.labels.filter { $0 == "recognitionCancelled" }.count == 1)
        #expect(calls.next() == 2)   // ハンドラが呼ばれたのは、a2 だけ（ここで数えるのが 2 回目）
    }

    @Test func escWhileExecutingCancelsTheTokenAndTheHandlerTask() async {
        let started = Mailbox<Void>()
        let finished = Mailbox<[Bool]>()
        let gate = Gate()
        let h = Harness { _, token, _, _ in
            started.put(())
            await gate.wait()
            finished.put([token.isCancelled, Task.isCancelled])
        }
        h.speak("a1")
        await started.take()
        h.escapeKey()
        gate.open()
        #expect(await finished.take() == [true, true])
        #expect(h.log.labels.contains("cancelling"))
    }

    @Test func escWhileRecordingDiscardsTheRecordingAndTheReleaseDoesNothing() async {
        let handled = Mailbox<String>()
        let h = Harness { utterance, _, _, _ in handled.put(utterance) }
        h.trigger.onPress?()
        h.escapeKey()
        #expect(h.recorder.discards == 1)
        h.trigger.onRelease?()   // 離しても、認識へ進まない
        #expect(h.recorder.stops == 0)
        #expect(h.log.labels == ["recordingStarted", "recordingDiscarded"])

        h.speak("a1")   // 次の録音は、普通に進む（「捨てた」の印は、1 度だけ）
        #expect(await handled.take() == "text-a1")
        #expect(h.recorder.stops == 1 && h.recorder.discards == 1)
    }

    @Test func escWhileWaitingForAConfirmationAnswerReleasesTheWait() async {
        let waiting = Mailbox<Void>()
        let answer = Mailbox<String?>()
        let cancelled = Mailbox<Bool>()
        let h = Harness { _, token, next, _ in
            waiting.put(())
            let reply = try? await next()
            answer.put(reply ?? nil)
            cancelled.put(token.isCancelled)
        }
        h.speak("a1")
        await waiting.take()
        h.escapeKey()
        #expect(await answer.take() == nil)   // 待ちが解けた（返事なし）
        #expect(await cancelled.take())
    }

    @Test func aConfirmationAnswerIsRecognizedAndReturned() async {
        let answer = Mailbox<String?>()
        let waiting = Mailbox<Void>()
        let h = Harness { _, _, next, _ in
            waiting.put(())
            answer.put((try? await next()) ?? nil)
        }
        h.speak("a1")
        await waiting.take()
        h.speak("yes")
        #expect(await answer.take() == "text-yes")
        #expect(h.log.labels.contains("recognized:text-yes"))
    }

    @Test func aStaleCancelSignalIsDiscardedByTheNextConfirmationWait() async {
        let started1 = Mailbox<Void>()
        let started2 = Mailbox<Void>()
        let answer = Mailbox<String?>()
        let gate1 = Gate()
        let count = Counter()
        let h = Harness { _, token, next, _ in
            switch count.next() {
            case 1:
                started1.put(())
                await gate1.wait()   // 待たずに（列を読まずに）終わる処理：Esc の .cancel は、列に残る
            default:
                started2.put(())
                let reply = try? await next()
                answer.put((reply ?? nil).map { $0 + (token.isCancelled ? "(cancelled)" : "") })
            }
        }
        h.speak("a1")
        await started1.take()
        h.speak("a2")        // 実行中に、次の発話が列に入る
        h.escapeKey()        // 実行中の処理を取りやめる：列は [a2, .cancel]
        gate1.open()
        await started2.take()   // 2 つ目の処理が、確認の返事を待つ。先頭の古い .cancel は、読み捨てられる
        h.speak("a3")
        #expect(await answer.take() == "text-a3")   // 取りやめられず、次の音声の認識結果が返る
    }

    /// 実行中に、新しく話すと、前の処理（トークン・`Task`）が取りやめられ、新しい発話が、そのあとに、1 つずつ処理される（同時には、動かない）。
    /// Esc の取りやめとは違い、「取りやめ」の出来事は出ない（新しい発話の表示を、上書きしない）。
    @Test func aNewUtteranceWhileExecutingCancelsTheCurrentWorkThenRunsTheNewOne() async {
        let started = Mailbox<String>()
        let finished = Mailbox<String>()
        let gate = Gate()
        let state = Concurrency()
        let tokens = Mailbox<[Bool]>()
        let h = Harness { utterance, token, _, _ in
            state.enter()
            started.put(utterance)
            if utterance == "text-a1" {
                await gate.wait()
                tokens.put([token.isCancelled, token.isSuperseded, Task.isCancelled])
            }
            finished.put(utterance)
            state.leave()
        }
        h.speak("a1")
        #expect(await started.take() == "text-a1")
        h.speak("a2")   // a1 の実行中
        gate.open()
        #expect(await tokens.take() == [true, true, true])
        #expect(await finished.take() == "text-a1")
        #expect(await started.take() == "text-a2")
        #expect(await finished.take() == "text-a2")
        #expect(state.maxInFlight == 1)
        #expect(h.log.labels.contains("interrupted"))
        #expect(!h.log.labels.contains("cancelling") && !h.log.labels.contains("recognitionCancelled"))
    }

    /// 認識の途中でも、新しく話すと、前の発話は、ハンドラに届かず（何も出さず）、新しい発話が処理される。
    @Test func aNewUtteranceWhileRecognizingDropsThePreviousOneSilently() async {
        let handled = Mailbox<String>()
        let gate = Gate()
        let h = Harness { utterance, _, _, _ in handled.put(utterance) }
        h.transcriber.hold("a1", gate)
        h.speak("a1")
        #expect(await h.transcriber.entered.take() == "a1")
        h.speak("a2")
        gate.open()
        #expect(await handled.take() == "text-a2")
        #expect(h.log.labels.contains("interrupted") && !h.log.labels.contains("recognitionCancelled"))
        #expect(!h.log.labels.contains("recognized:text-a1"))
    }

    /// 確認の返事を待っている間に来た発話は、新しい依頼ではなく、返事（中断しない）。
    @Test func anUtteranceWhileWaitingForAConfirmationAnswerIsTheAnswerNotAnInterruption() async {
        let result = Mailbox<[String]>()
        let waiting = Mailbox<Void>()
        let h = Harness { _, token, next, _ in
            waiting.put(())
            let answer = (try? await next()) ?? nil
            result.put([answer ?? "nil", String(token.isCancelled)])
        }
        h.speak("a1")
        await waiting.take()
        h.speak("yes")
        #expect(await result.take() == ["text-yes", "false"])
        #expect(!h.log.labels.contains("interrupted"))
    }

    /// 何も録音できなかった（空）・録音の失敗では、実行中の処理を、中断しない。
    @Test func anEmptyRecordingDoesNotInterruptTheCurrentWork() async {
        let started = Mailbox<Void>()
        let finished = Mailbox<Bool>()
        let gate = Gate()
        let h = Harness { _, token, _, _ in
            started.put(())
            await gate.wait()
            finished.put(token.isCancelled)
        }
        h.speak("a1")
        await started.take()
        h.recorder.enqueue(.success(nil))
        h.trigger.onPress?()
        h.trigger.onRelease?()   // 何も録音できなかった
        gate.open()
        #expect(await finished.take() == false)
        #expect(!h.log.labels.contains("interrupted"))
    }

    @Test func recognitionFailureIsReportedAndTheHandlerIsNotCalled() async {
        let handled = Mailbox<String>()
        let h = Harness { utterance, _, _, _ in handled.put(utterance) }
        h.transcriber.fail("bad")
        h.speak("bad")
        await h.log.wait(for: "recognitionFailed")
        h.speak("a1")
        #expect(await handled.take() == "text-a1")   // 失敗のあとも、続く
    }

    @Test func recordingFailureAndAnEmptyRecordingAreReported() {
        let h = Harness { _, _, _, _ in }
        h.recorder.enqueue(.failure(RecorderFailure()))
        h.trigger.onPress?()
        h.trigger.onRelease?()
        h.recorder.enqueue(.success(nil))
        h.trigger.onPress?()
        h.trigger.onRelease?()
        #expect(h.log.labels == ["recordingStarted", "recognizing", "recordingFailed", "recordingStarted", "recognizing", "recordingEmpty"])
        h.main.runImmediate()
        #expect(h.escape.setActiveCalls == [true, false, true, false])   // 何も認識に回らなければ、Esc は、受けないまま
    }

    @Test func escWhileIdleDoesNothing() {
        let h = Harness { _, _, _, _ in }
        h.escapeKey()
        #expect(h.log.labels.isEmpty && h.recorder.discards == 0)
    }

    // MARK: 不変条件（VoiceLoop のコメントの 1〜3）

    /// 不変条件 1：`run(onReady:)` は、同期（`async` にすると、この型が合わず、コンパイルが通らない）。
    @Test func runIsSynchronousSoNothingIsAwaitedBeforeTheEventLoop() {
        let h = Harness { _, _, _, _ in }
        let run: @MainActor (() -> Void) -> Void = h.loop.run(onReady:)
        _ = run
    }

    /// 不変条件 2：トリガーと Esc は、`VoiceLoop` が持つ（呼び出し側が手放しても、解放されない）。`run()` の間は、さらに `withExtendedLifetime` で持つ。
    @Test func theLoopOwnsTheTriggerAndEscape() {
        weak var weakTrigger: FakeTrigger?
        weak var weakEscape: FakeEscape?
        let loop: VoiceLoop = {
            let trigger = FakeTrigger(), escape = FakeEscape()
            weakTrigger = trigger
            weakEscape = escape
            return VoiceLoop(trigger: trigger, escape: escape, recorder: FakeRecorder(), transcriber: FakeTranscriber(), handler: { _, _, _, _ in }, onEvent: { _, _ in })
        }()
        #expect(weakTrigger != nil && weakEscape != nil)
        withExtendedLifetime(loop) {}
    }

    /// 不変条件 3：Esc を受ける用意は、押した直後（修飾キーを押している間）と、離したあと（登録し直し）の両方で、行う。
    /// 離したあとは、遅延をおいて数回（修飾キーが離れるまで）。処理が終わったあとに遅れて届いたタイマーは、Esc を受けない。
    @Test func escIsArmedOnPressAndRearmedAfterTheReleaseButNotAfterTheWorkEnds() async {
        let started = Mailbox<Void>()
        let gate = Gate()
        let done = Mailbox<Void>()
        let h = Harness(rearmDelays: [0.05, 0.3]) { _, _, _, _ in
            started.put(())
            await gate.wait()
            done.put(())
        }
        h.trigger.onPress?()
        h.main.runImmediate()
        #expect(h.escape.setActiveCalls == [true])   // 押している間に、受ける用意（修飾キーを押している間は、グローバルのキー監視だけが効く）
        #expect(h.main.delayed.isEmpty)

        h.recorder.enqueue(.success(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("a1")))
        h.trigger.onRelease?()
        #expect(h.main.delayed.map(\.delay) == [0.05, 0.3])   // 離したあと：遅延をおいて、登録し直す
        h.main.runDelayed()
        #expect(h.escape.setActiveCalls == [true, true, true])
        await started.take()

        gate.open()
        await done.take()
        // 処理が終わると、受けるのをやめる。
        while h.escape.setActiveCalls.last != false {
            h.main.runImmediate()
            await Task.yield()
        }
        let before = h.escape.setActiveCalls
        h.main.runDelayed()   // 遅れて届いたタイマー：もう活動中ではないので、登録し直さない
        #expect(h.escape.setActiveCalls == before)
    }
}

/// トリガーで、録音ごとの印（声で頼む／音声入力）が、出来事と発話の処理に、正しく届く。
@MainActor @Suite struct ModeTriggerTests {
    private func fixture() -> (a: FakeTrigger, b: FakeTrigger, mode: ModeTrigger) {
        let a = FakeTrigger(), b = FakeTrigger()
        return (a, b, ModeTrigger([(tag: "listen", trigger: a), (tag: "dictate", trigger: b)]))
    }

    @Test func theTagIsTheTriggerThatStartedTheRecordingAndOthersAreIgnoredMeanwhile() {
        let (a, b, mode) = fixture()
        var presses = 0, releases = 0
        mode.onPress = { presses += 1 }
        mode.onRelease = { releases += 1 }
        b.onPress?()
        #expect(mode.tag == "dictate" && presses == 1)
        a.onPress?()      // 録音中の、別のトリガーの「押した」は、無視する
        a.onRelease?()    // 押していないトリガーの「離した」も、無視する
        #expect(mode.tag == "dictate" && presses == 1 && releases == 0)
        b.onRelease?()
        #expect(releases == 1)
        a.onPress?()      // 離したあとは、別のトリガーでも、始められる
        #expect(mode.tag == "listen" && presses == 2)
    }

    /// 録音の印が、その録音の発話の処理と、出来事へ、順どおりに届く（声で頼む → 音声入力 → 声で頼む）。
    @Test func eachUtteranceIsHandledWithTheTagOfItsOwnTrigger() async {
        let a = FakeTrigger(), b = FakeTrigger()
        let mode = ModeTrigger([(tag: "listen", trigger: a), (tag: "dictate", trigger: b)])
        let handled = Mailbox<String>()
        let events = EventTags()
        let recorder = FakeRecorder()
        let loop = VoiceLoop(trigger: mode, escape: FakeEscape(), recorder: recorder, transcriber: FakeTranscriber(),
                             handler: { utterance, _, _, tag in handled.put("\(tag):\(utterance)") },
                             onEvent: { event, tag in events.add(event, tag) })
        loop.start()
        for (trigger, name) in [(a, "x1"), (b, "x2"), (a, "x3")] {
            recorder.enqueue(.success(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)))
            trigger.onPress?()
            trigger.onRelease?()
        }
        var got: [String] = []
        for _ in 0..<3 { got.append(await handled.take()) }
        #expect(got == ["listen:text-x1", "dictate:text-x2", "listen:text-x3"])
        #expect(events.tags(of: "recordingStarted") == ["listen", "dictate", "listen"])
        #expect(events.tags(of: "recognized") == ["listen", "dictate", "listen"])
    }
}

/// 出来事の印を、出来事の種類ごとに集める。
final class EventTags: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, String)] = []
    func add(_ event: VoiceLoopEvent, _ tag: String) {
        let kind: String
        switch event {
        case .recordingStarted: kind = "recordingStarted"
        case .recognized: kind = "recognized"
        default: kind = "other"
        }
        lock.lock(); items.append((kind, tag)); lock.unlock()
    }
    func tags(of kind: String) -> [String] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.0 == kind }.map(\.1) }
}

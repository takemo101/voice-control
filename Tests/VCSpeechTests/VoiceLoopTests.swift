import Foundation
import Testing
@testable import VCSpeech
import VCCore

// `VoiceLoop`（声の流れの調整）の単体テスト。マイク・音声認識・Carbon のホットキーは使わず、録音・文字起こし・トリガー・Esc を偽物に差し替える。
// 待つのは、継続（`Mailbox`・`Gate`）だけ（スリープで待たない）。メインキューへの回し（Esc を受ける用意・登録し直し）は、`ManualScheduler` で手で動かす。

// MARK: - 偽物と道具

/// 値を 1 つずつ渡す（どのスレッドから入れてもよい。取り出しはメインアクターで 1 人）。
private final class Mailbox<T: Sendable>: @unchecked Sendable {
    private let continuation: AsyncStream<T>.Continuation
    private var iterator: AsyncStream<T>.Iterator

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: T.self)
        self.continuation = continuation
        iterator = stream.makeAsyncIterator()
    }

    func put(_ value: T) { continuation.yield(value) }
    @MainActor func take() async -> T { await iterator.next()! }
}

/// 開くまで `wait()` が待つ（認識・処理を、テストが決めた時点まで止めておく）。
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened { lock.unlock(); continuation.resume() } else { waiters.append(continuation); lock.unlock() }
        }
    }

    func open() {
        lock.lock(); opened = true; let pending = waiters; waiters = []; lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class FakeTrigger: PushToTalkTrigger, @unchecked Sendable {
    var onPress: (@Sendable () -> Void)?
    var onRelease: (@Sendable () -> Void)?
}

private final class FakeEscape: EscapeSource, @unchecked Sendable {
    var onEscape: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var calls: [Bool] = []
    func setActive(_ active: Bool) -> Bool { lock.lock(); calls.append(active); lock.unlock(); return true }
    var setActiveCalls: [Bool] { lock.lock(); defer { lock.unlock() }; return calls }
}

private struct RecorderFailure: Error {}

private final class FakeRecorder: Recording, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<URL?, Error>] = []
    private(set) var starts = 0, discards = 0, stops = 0

    /// 次の `stop()` の結果。
    func enqueue(_ result: Result<URL?, Error>) { lock.lock(); results.append(result); lock.unlock() }
    func start() { lock.lock(); starts += 1; lock.unlock() }
    func discard() { lock.lock(); discards += 1; lock.unlock() }
    func stop() throws -> URL? {
        lock.lock(); stops += 1; let next = results.isEmpty ? .success(nil) : results.removeFirst(); lock.unlock()
        return try next.get()
    }
}

private final class FakeTranscriber: Transcribing, @unchecked Sendable {
    let entered = Mailbox<String>()
    private let lock = NSLock()
    private var gates: [String: Gate] = [:]
    private var failing: Set<String> = []

    /// このファイルの認識を、`gate` が開くまで止める。
    func hold(_ name: String, _ gate: Gate) { lock.lock(); gates[name] = gate; lock.unlock() }
    func fail(_ name: String) { lock.lock(); failing.insert(name); lock.unlock() }

    private func plan(for name: String) -> (gate: Gate?, fails: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (gates[name], failing.contains(name))
    }

    func transcribe(file url: URL) async throws -> String {
        let name = url.lastPathComponent
        let (gate, fails) = plan(for: name)
        entered.put(name)
        if let gate { await gate.wait() }
        if fails { throw RecorderFailure() }
        return "text-" + name
    }
}

/// メインキューの代わり：回された手続きを、テストが動かす。
private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var immediate: [@Sendable () -> Void] = []
    private(set) var delayed: [(delay: TimeInterval, work: @Sendable () -> Void)] = []

    var scheduler: VoiceLoop.Scheduler {
        VoiceLoop.Scheduler(
            onMain: { [self] work in lock.lock(); immediate.append(work); lock.unlock() },
            afterOnMain: { [self] delay, work in lock.lock(); delayed.append((delay, work)); lock.unlock() })
    }

    /// たまっている「すぐ」の手続きを、順に動かす。
    func runImmediate() {
        lock.lock(); let pending = immediate; immediate = []; lock.unlock()
        pending.forEach { $0() }
    }

    /// 遅延つきの手続きを、すべて動かす（何度でも：遅れて届いたタイマーの再現）。
    func runDelayed() { lock.lock(); let pending = delayed; lock.unlock(); pending.forEach { $0.work() } }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private let mailbox = Mailbox<String>()

    func add(_ event: VoiceLoopEvent) {
        let label: String
        switch event {
        case .recordingStarted: label = "recordingStarted"
        case .recordingDiscarded: label = "recordingDiscarded"
        case .recognizing: label = "recognizing"
        case .recordingEmpty: label = "recordingEmpty"
        case .recordingFailed: label = "recordingFailed"
        case let .recognized(text): label = "recognized:" + text
        case .recognitionCancelled: label = "recognitionCancelled"
        case .recognitionFailed: label = "recognitionFailed"
        case .cancelling: label = "cancelling"
        }
        lock.lock(); items.append(label); lock.unlock()
        mailbox.put(label)
    }

    var labels: [String] { lock.lock(); defer { lock.unlock() }; return items }

    /// `label` の出来事が届くまで待つ。
    @MainActor func wait(for label: String) async {
        while await mailbox.take() != label {}
    }
}

/// 偽物をつないだ `VoiceLoop`（配線済み）。
@MainActor private final class Harness {
    let trigger = FakeTrigger()
    let escape = FakeEscape()
    let recorder = FakeRecorder()
    let transcriber = FakeTranscriber()
    let main = ManualScheduler()
    let log = EventLog()
    let loop: VoiceLoop

    init(rearmDelays: [TimeInterval] = [0.05, 0.3], handler: @escaping UtteranceHandler) {
        let log = self.log
        loop = VoiceLoop(trigger: trigger, escape: escape, recorder: recorder, transcriber: transcriber, handler: handler,
                         scheduler: main.scheduler, rearmDelays: rearmDelays, onEvent: { log.add($0) })
        loop.start()
    }

    /// 押して、離す（`name` の音声が、認識の列に入る。認識の結果は "text-<name>"）。
    func speak(_ name: String) {
        recorder.enqueue(.success(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)))
        trigger.onPress?()
        trigger.onRelease?()
    }

    func escapeKey() { escape.onEscape?() }
}

// MARK: - テスト

@MainActor @Suite(.timeLimit(.minutes(1))) struct VoiceLoopTests {
    @Test func utteranceReachesTheHandlerAndTheTemporaryFileIsRemoved() async throws {
        let handled = Mailbox<String>()
        let fileGone = Mailbox<Bool>()
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vc-loop-\(UUID().uuidString).caf")
        try Data("x".utf8).write(to: file)
        let h = Harness { utterance, token, _ in
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
        let h = Harness { utterance, token, _ in
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
        let h = Harness { _, token, _ in
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
        let h = Harness { utterance, _, _ in handled.put(utterance) }
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
        let h = Harness { _, token, next in
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
        let h = Harness { _, _, next in
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
        let h = Harness { _, token, next in
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

    @Test func queuedAudioIsHandledOneAtATimeInOrder() async {
        let order = Mailbox<String>()
        let gate = Gate()
        let state = Concurrency()
        let h = Harness { utterance, _, _ in
            state.enter()
            if utterance == "text-a1" { await gate.wait() }   // 1 つ目の処理中に、2・3 が列にたまる
            order.put(utterance)
            state.leave()
        }
        h.speak("a1")
        #expect(await h.transcriber.entered.take() == "a1")
        h.speak("a2")
        h.speak("a3")
        gate.open()
        #expect(await order.take() == "text-a1")
        #expect(await order.take() == "text-a2")
        #expect(await order.take() == "text-a3")
        #expect(state.maxInFlight == 1)
    }

    @Test func recognitionFailureIsReportedAndTheHandlerIsNotCalled() async {
        let handled = Mailbox<String>()
        let h = Harness { utterance, _, _ in handled.put(utterance) }
        h.transcriber.fail("bad")
        h.speak("bad")
        await h.log.wait(for: "recognitionFailed")
        h.speak("a1")
        #expect(await handled.take() == "text-a1")   // 失敗のあとも、続く
    }

    @Test func recordingFailureAndAnEmptyRecordingAreReported() {
        let h = Harness { _, _, _ in }
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
        let h = Harness { _, _, _ in }
        h.escapeKey()
        #expect(h.log.labels.isEmpty && h.recorder.discards == 0)
    }

    // MARK: 不変条件（VoiceLoop のコメントの 1〜3）

    /// 不変条件 1：`run(onReady:)` は、同期（`async` にすると、この型が合わず、コンパイルが通らない）。
    @Test func runIsSynchronousSoNothingIsAwaitedBeforeTheEventLoop() {
        let h = Harness { _, _, _ in }
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
            return VoiceLoop(trigger: trigger, escape: escape, recorder: FakeRecorder(), transcriber: FakeTranscriber(), handler: { _, _, _ in }, onEvent: { _ in })
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
        let h = Harness(rearmDelays: [0.05, 0.3]) { _, _, _ in
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

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private final class Concurrency: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0
    func enter() { lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock() }
    func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
}

import Foundation
@testable import VCSpeech
import VCCore

// `VoiceLoopTests` が使う偽物と道具。待つのは、継続（`Mailbox`・`Gate`）だけ（スリープで待たない）。メインキューへの回し（Esc を受ける用意・登録し直し）は、`ManualScheduler` で手で動かす。

/// 値を 1 つずつ渡す（どのスレッドから入れてもよい。取り出しはメインアクターで 1 人）。
final class Mailbox<T: Sendable>: @unchecked Sendable {
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
final class Gate: @unchecked Sendable {
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

@MainActor final class FakeTrigger: PushToTalkTrigger {
    var onPress: (@Sendable () -> Void)?
    var onRelease: (@Sendable () -> Void)?
}

@MainActor final class FakeEscape: EscapeSource {
    var onEscape: (@Sendable () -> Void)?
    private(set) var setActiveCalls: [Bool] = []
    func setActive(_ active: Bool) -> Bool { setActiveCalls.append(active); return true }
}

struct RecorderFailure: Error {}

final class FakeRecorder: Recording, @unchecked Sendable {
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

final class FakeTranscriber: Transcribing, @unchecked Sendable {
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
final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var immediate: [@MainActor @Sendable () -> Void] = []
    private(set) var delayed: [(delay: TimeInterval, work: @MainActor @Sendable () -> Void)] = []

    var scheduler: VoiceLoop.Scheduler {
        VoiceLoop.Scheduler(
            onMain: { [self] work in lock.lock(); immediate.append(work); lock.unlock() },
            afterOnMain: { [self] delay, work in lock.lock(); delayed.append((delay, work)); lock.unlock() })
    }

    /// たまっている「すぐ」の手続きを、順に動かす。
    @MainActor func runImmediate() {
        lock.lock(); let pending = immediate; immediate = []; lock.unlock()
        pending.forEach { $0() }
    }

    /// 遅延つきの手続きを、すべて動かす（何度でも：遅れて届いたタイマーの再現）。
    @MainActor func runDelayed() { lock.lock(); let pending = delayed; lock.unlock(); pending.forEach { $0.work() } }
}

final class EventLog: @unchecked Sendable {
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
@MainActor final class Harness {
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
                         scheduler: main.scheduler, rearmDelays: rearmDelays, onEvent: { event, _ in log.add(event) })
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

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

final class Concurrency: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0
    func enter() { lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock() }
    func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
}

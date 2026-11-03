import Foundation
import VCCore

/// 声の流れ（`vc listen --hotkey`）に届く入力：録音した音声か、Esc による取りやめの合図（待っている処理を起こす）。
enum VoiceInput: Sendable {
    case audio(URL)
    case cancel
}

/// 入力の列（1 人が取り出す）。`next()` は、入力が来るまで待つ。Esc の `.cancel` が、待っている処理を起こす。
final class VoiceInputQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [VoiceInput] = []
    private var waiter: CheckedContinuation<VoiceInput, Never>?

    init() {}

    func push(_ input: VoiceInput) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: input)
        } else {
            items.append(input)
            lock.unlock()
        }
    }

    func next() async -> VoiceInput {
        await withCheckedContinuation { continuation in
            lock.lock()
            if items.isEmpty {
                waiter = continuation
                lock.unlock()
            } else {
                let first = items.removeFirst()
                lock.unlock()
                continuation.resume(returning: first)
            }
        }
    }
}

/// 声の流れの「いま、何をしているか」：録音中・認識待ちの音声・実行中。**Esc は、どれかをしている間だけ**受ける（`isActive`）。
/// Esc が来たら、録音中なら録音を捨て、そうでなければ、実行中の処理を取りやめる（`CancelToken`・`Task`）。
final class VoiceActivity: @unchecked Sendable {
    enum Target: Equatable, Sendable { case recording, work, nothing }

    private let lock = NSLock()
    private var recording = false
    private var cancelledRecording = false
    private var queued = 0
    private var running = false
    private var token: CancelToken?
    private var task: Task<Void, Never>?
    private var lastActive = false

    init() {}

    /// いま、Esc を受けるべきか（録音中・認識待ち・実行中）。
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return recording || queued > 0 || running }

    /// 「Esc を受けるべきか」が変わったときに呼ぶ（どのスレッドからでも呼ばれる）。
    var onChange: (@Sendable (Bool) -> Void)?

    private func commit(_ change: () -> Void) {
        lock.lock()
        change()
        let active = recording || queued > 0 || running
        let changed = active != lastActive
        lastActive = active
        let callback = onChange
        lock.unlock()
        if changed { callback?(active) }
    }

    func startRecording() { commit { recording = true; cancelledRecording = false } }

    /// 録音を終えた。`queuedAudio`：音声を、認識の列に入れた。
    func stopRecording(queuedAudio: Bool) { commit { recording = false; if queuedAudio { queued += 1 } } }

    /// Esc で録音を捨てていたら true（そのあとの「離した」は、何もしない）。
    func consumeCancelledRecording() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = cancelledRecording
        cancelledRecording = false
        return was
    }

    /// 列の音声を、取り出した（認識に回す）。
    func consumedAudio() { commit { queued = max(0, queued - 1) } }

    func beginWork(_ token: CancelToken) { commit { self.token = token; running = true } }
    func setTask(_ task: Task<Void, Never>) { lock.lock(); self.task = task; lock.unlock() }
    func endWork() { commit { running = false; token = nil; task = nil } }

    /// Esc：録音中なら、録音を捨てる。そうでなく、処理中なら、取りやめる。
    func escape() -> Target {
        var target = Target.nothing
        var toCancel: (CancelToken?, Task<Void, Never>?) = (nil, nil)
        commit {
            if recording {
                recording = false; cancelledRecording = true
                target = .recording
            } else if running || queued > 0 {
                toCancel = (token, task)
                target = .work
            }
        }
        toCancel.0?.cancel()
        toCancel.1?.cancel()
        return target
    }
}

import Foundation
import VCCore

/// 声の流れ（声の入力）に届く入力：録音した音声か、Esc による取りやめの合図（待っている処理を起こす）。
enum VoiceInput: Sendable {
    case audio(URL)
    /// 認識済みの発話（会話の順番待ちが、順番になった：認識は、すでに済んでいる）。`tag`：どの流れの発話か。
    case text(String, tag: String)
    case cancel
}

/// 入力の列（1 人が取り出す）。`next()` は、入力が来るまで待つ。Esc の `.cancel` が、待っている処理を起こす。
/// `@unchecked Sendable` の理由：可変な状態（`items`・`waiter`）は、すべて `lock` で守る。
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

    /// 入力が来るまで待つ。**待っている `Task` が取りやめられたら、`.cancel` で戻る**（確認で、パネルのボタンが先に押されたとき、声の返事を待つ処理が、次の発話を横取りしないように）。
    func next() async -> VoiceInput {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !items.isEmpty {
                    let first = items.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: first)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: .cancel)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiting = waiter
            waiter = nil
            lock.unlock()
            waiting?.resume(returning: .cancel)
        }
    }
}

/// 声の流れの「いま、何をしているか」：録音中・認識待ちの音声・実行中。**Esc は、どれかをしている間だけ**受ける（`isActive`）。
/// Esc が来たら、録音中なら録音を捨て、そうでなければ、実行中の処理を取りやめる（`CancelToken`・`Task`）。
/// `@unchecked Sendable` の理由：可変な状態は、すべて `lock` で守る（`onChange` も、`lock` の中で読み書きする）。
final class VoiceActivity: @unchecked Sendable {
    enum Target: Equatable, Sendable { case recording, work, nothing }

    private let lock = NSLock()
    private var recording = false
    private var cancelledRecording = false
    private var queued = 0
    private var running = false
    /// 実行中の処理の印（どの流れの発話か）。新しい発話が、実行中の処理を、取りやめるかの判断に使う。
    private var runningTag: String?
    /// 実行中の処理が、認識を終えて、**発話の処理（`handler`）に入っている**か。
    private var handling = false
    private var awaitingReply = 0
    private var token: CancelToken?
    private var task: Task<Void, Never>?
    private var lastActive = false
    private var changeHandler: (@Sendable (Bool) -> Void)?

    init() {}

    /// いま、Esc を受けるべきか（録音中・認識待ち・実行中）。
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return recording || queued > 0 || running }

    /// 「Esc を受けるべきか」が変わったときに呼ぶ（どのスレッドからでも呼ばれる）。
    var onChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    private func commit(_ change: () -> Void) {
        lock.lock()
        change()
        let active = recording || queued > 0 || running
        let changed = active != lastActive
        lastActive = active
        let callback = changeHandler
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

    /// 確認の返事（次の発話）を待っている間。この間に来た発話は、新しい依頼ではなく、返事。
    func beginAwaitingReply() { lock.lock(); awaitingReply += 1; lock.unlock() }
    func endAwaitingReply() { lock.lock(); awaitingReply = max(0, awaitingReply - 1); lock.unlock() }

    /// 新しい発話が来た：**実行中（認識中を含む）の処理を、取りやめる**（新しい依頼を、先に進めるため）。
    /// 確認の返事を待っている間は、取りやめない（来た発話は、返事）。取りやめたら true。
    func interruptForNewUtterance() -> Bool {
        lock.lock()
        guard running, awaitingReply == 0 else { lock.unlock(); return false }
        let (token, task) = (self.token, self.task)
        lock.unlock()
        token?.supersede()
        task?.cancel()
        return true
    }

    /// 実行中の処理があるときの、新しい発話の扱い（`keepsRunning`：実行中の処理の印を見て、**取りやめずに待たせる**か。会話の質問に、続けて話したとき）。
    /// - `interrupt`：従来どおり、取って代わる（実行中でない・別の流れ）。確認の返事を待っている間も、ここ（来た発話は、返事：取りやめは、しない）。
    /// - `recognizeNow`：実行中の処理は、続ける。この発話は、**その場で先に認識**して、順番待ちに並べる（実行中の処理が、発話の処理に入っているとき）。
    /// - `queueBehind`：実行中の処理は、続ける。この発話は、列で、順番を待つ（実行中の処理が、まだ認識中のとき：**順番が、入れ替わらないように**、先に認識して並べない）。
    enum NewUtteranceDisposition: Equatable, Sendable { case interrupt, recognizeNow, queueBehind }
    func disposition(keepsRunning: (String?) -> Bool) -> NewUtteranceDisposition {
        lock.lock(); defer { lock.unlock() }
        guard running, awaitingReply == 0, keepsRunning(runningTag) else { return .interrupt }
        return handling ? .recognizeNow : .queueBehind
    }

    /// 実行中の処理を、いますぐ、取りやめる（会話の「今すぐ送る」：確認の返事を待っていても、やめる）。取りやめたら true。
    func interruptRunning() -> Bool {
        lock.lock()
        guard running else { lock.unlock(); return false }
        let (token, task) = (self.token, self.task)
        lock.unlock()
        token?.supersede()
        task?.cancel()
        return true
    }

    func beginWork(_ token: CancelToken, tag: String? = nil) { commit { self.token = token; runningTag = tag; handling = false; running = true } }

    /// 認識を終えて、発話の処理に入った（`defersNewUtterance` の判断に使う）。
    func beginHandling() { lock.lock(); handling = true; lock.unlock() }
    func setTask(_ task: Task<Void, Never>) { lock.lock(); self.task = task; lock.unlock() }
    func endWork() { commit { running = false; runningTag = nil; handling = false; token = nil; task = nil } }

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

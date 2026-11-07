import AppKit
import Foundation
import VCCore

// MARK: - 差し替え口
// 差し替えるのは、実機（マイク・音声認識・キー）でしか動かない所だけ：録音・文字起こし・トリガー（`PushToTalkTrigger`）・Esc。

/// 音声ファイルを文字にする。実装は `FileTranscriber`。
public protocol Transcribing: Sendable {
    func transcribe(file url: URL) async throws -> String
}

extension FileTranscriber: Transcribing {}

/// 1 回分の録音（押した → 離した）。実装は `RecordingSession`。
public protocol Recording: AnyObject, Sendable {
    func start()
    /// 録音を捨てる（Esc）。ファイルは消す。
    func discard()
    /// 録音したファイル。始まっていなければ `nil`（始めに失敗していれば、その失敗を投げる）。
    func stop() throws -> URL?
}

extension RecordingSession: Recording {}

/// Esc の受け付け。実装は `EscapeKey`（Carbon のホットキー・グローバルのキー監視）。
@MainActor public protocol EscapeSource: AnyObject, Sendable {
    var onEscape: (@Sendable () -> Void)? { get set }
    /// 受け付けを始める・やめる。始める方は、何度呼んでもよい。
    @discardableResult func setActive(_ active: Bool) -> Bool
}

extension EscapeKey: EscapeSource {}

// MARK: - 出来事と、外から渡す処理

/// `VoiceLoop` が、表示（画面の上・端末）のために知らせる出来事。**どのスレッドからでも呼ばれる**（実際は、キーのイベントはメインスレッド、認識の結果はメインアクター）。
public enum VoiceLoopEvent: Sendable {
    /// トリガーを押した（録音を始める前に届く）。
    case recordingStarted
    /// Esc で録音を捨てた（そのあとの「離した」は、何もしない）。
    case recordingDiscarded
    /// トリガーを離した（認識を待つ。録音の取り出しの前に届く）。
    case recognizing
    /// 離したが、録音が始まっていなかった（取り出した音声がない）。
    case recordingEmpty
    case recordingFailed(Error)
    /// 文字になった（1 つ目の発話にも、確認の返事にも届く）。
    case recognized(String)
    /// 文字にする間（またはその前）に、取りやめられた。ハンドラは呼ばれない。
    case recognitionCancelled
    /// 文字にできなかった（取りやめではない）。ハンドラは呼ばれない。
    case recognitionFailed(Error)
    /// Esc で、認識・実行・確認の待ちの取りやめを始めた。
    case cancelling
    /// 処理の途中で、新しい発話が来たので、前の処理を取りやめた（Esc ではない）。そのあと、新しい発話を、順に処理する。
    case interrupted
}

/// 次の発話（確認の返事など）を待つ。取りやめられたら `nil`。待っている間の Esc で、解ける。
public typealias NextUtterance = @MainActor @Sendable () async throws -> String?

/// 1 回の発話の処理（スキルの振り分けなど）。`VoiceLoop` は、中身を知らない。
/// - `utterance`：文字にした発話（聞き取れなければ空）。
/// - `cancel`：Esc で取りやめられる。実行中の処理は、これを見て止まる（処理の `Task` も取りやめられる）。
/// - `next`：確認の返事など、次の発話を待つ。
/// 処理の中の失敗・取りやめの表示は、ハンドラの仕事（文字にする段階のものは、`VoiceLoopEvent`）。
/// - `tag`：この録音を始めたトリガーの印（`TaggedTrigger.tag`。トリガーが 1 つなら、空）。`vc listen --hotkey` が、声で頼む／音声入力を、トリガーで切り替えるのに使う。
public typealias UtteranceHandler = @MainActor @Sendable (_ utterance: String, _ cancel: CancelToken, _ next: @escaping NextUtterance, _ tag: String) async -> Void

/// 録音を始めたトリガーを、見分けられるトリガー（複数のトリガーを 1 つにまとめた `ModeTrigger`）。録音の間と、離した直後は、その印を返す。
@MainActor public protocol TaggedTrigger: PushToTalkTrigger {
    var tag: String { get }
}

/// 録音ごとの印を、認識の列と同じ順に渡す（音声が列に入るときに足し、取り出すときに引く）。
/// `@unchecked Sendable` の理由：`items` は、すべて `lock` で守る。
final class TagQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func push(_ tag: String) { lock.lock(); items.append(tag); lock.unlock() }
    func pop() -> String { lock.lock(); defer { lock.unlock() }; return items.isEmpty ? "" : items.removeFirst() }
}

// MARK: - VoiceLoop

/// 声の流れ（`vc listen --hotkey`）の**調整**：トリガー（押した・離した）・録音・Esc・認識の待ち行列・発話ごとの処理の `Task`。
/// 状態の遷移は `VoiceActivity`、入力の列は `VoiceInputQueue`。スキル・画面の表示は、知らない（`UtteranceHandler`・`VoiceLoopEvent` の向こう側）。
///
/// **守る不変条件**（実際に起きた不具合）：
/// 1. **`run(onReady:)` は同期**で、`NSApplication.run()` の前に `await` を挟まない。`await` のあとの処理は、メインキューのブロックの中で動き、
///    そこから `run()` を呼ぶと、`DispatchQueue.main` に回した処理（画面の表示・長押しの判定の遅延）が動かない。呼ぶ側（`vc listen`）も、`run` の前に `await` しない
///    （マイクの許可は同期の `MicRecorder.authorize()`）。
/// 2. **トリガーと Esc は、`run()` の間、手放さない**（`withExtendedLifetime`）。最適化で、最後の使用のあとに解放されると、ホットキーが死ぬ。
/// 3. **修飾キーを押している間は、Esc の Carbon ホットキーを登録しない**（登録すると、そのあとの Esc が届かない：実測）。それを守るのは `EscapeKey.setActive(true)` で、
///    修飾キーが押されていれば、グローバルのキー監視だけを足して、ホットキーの登録は見送る。だから、押した直後（録音の開始）に `setActive(true)` を呼んでよい。
///    見送った登録は、**離したあとに、もう一度 `setActive(true)` を呼んで、登録し直す**（修飾キーが離れるまでの間、数回試す：`rearmDelays`）。活動が終わっていれば、登録し直さない。
public final class VoiceLoop {
    /// メインキューへ回す手続き（遅延つきを含む）。テストで、手で動かせるように差し替える。
    struct Scheduler: Sendable {
        var onMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
        var afterOnMain: @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

        // メインキューのブロックは、メインアクターの上で動く（`assumeIsolated`）。
        static let mainQueue = Scheduler(
            onMain: { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } },
            afterOnMain: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } } })
    }

    private let trigger: PushToTalkTrigger
    private let escape: EscapeSource
    private let recorder: Recording
    private let transcriber: Transcribing
    private let handler: UtteranceHandler
    private let emit: @Sendable (VoiceLoopEvent, String) -> Void
    private let tags = TagQueue()
    private let scheduler: Scheduler
    private let rearmDelays: [TimeInterval]
    private let activity = VoiceActivity()
    private let queue = VoiceInputQueue()

    /// - `onEvent`：表示のための出来事（`VoiceLoopEvent`）。
    public convenience init(trigger: PushToTalkTrigger, escape: EscapeSource, recorder: Recording, transcriber: Transcribing,
                            handler: @escaping UtteranceHandler, onEvent: @escaping @Sendable (VoiceLoopEvent, String) -> Void) {
        self.init(trigger: trigger, escape: escape, recorder: recorder, transcriber: transcriber, handler: handler,
                  scheduler: .mainQueue, rearmDelays: [0.05, 0.3, 0.8, 1.5], onEvent: onEvent)
    }

    init(trigger: PushToTalkTrigger, escape: EscapeSource, recorder: Recording, transcriber: Transcribing, handler: @escaping UtteranceHandler,
         scheduler: Scheduler, rearmDelays: [TimeInterval], onEvent: @escaping @Sendable (VoiceLoopEvent, String) -> Void) {
        self.trigger = trigger
        self.escape = escape
        self.recorder = recorder
        self.transcriber = transcriber
        self.handler = handler
        self.scheduler = scheduler
        self.rearmDelays = rearmDelays
        self.emit = onEvent
    }

    /// 聞き始めて、アプリのイベントループ（`NSApplication.run()`）を回す（終わらない）。`onReady`：準備ができたときの表示（イベントループの前に、同期で呼ぶ）。
    /// 順序：配線 → `onReady` → `setActivationPolicy` → `run()`。**ここに `await` を足さない**（不変条件 1）。
    @MainActor public func run(onReady: () -> Void) {
        start()
        onReady()
        NSApplication.shared.setActivationPolicy(.accessory)
        // トリガーと Esc は、`run()` が終わるまで手放さない（不変条件 2）。
        withExtendedLifetime((trigger, escape)) { NSApplication.shared.run() }
    }

    /// トリガー・Esc の受け口を配線して、発話を順に処理する `Task` を始める（メインアクターの `Task`：呼び出し元の隔離を引き継ぐ）。
    @MainActor func start() {
        // 受け口のクロージャは、`self` ではなく、必要な部品だけを持つ（トリガー → クロージャ → `self` → トリガーの循環を作らない）。
        let activity = self.activity, queue = self.queue, recorder = self.recorder, escape = self.escape
        let emit = self.emit, scheduler = self.scheduler, rearmDelays = self.rearmDelays, tags = self.tags
        // 録音を始めたトリガーの印（トリガー → クロージャ → トリガーの循環を作らないよう、弱く持つ）
        weak let tagged = trigger as? TaggedTrigger
        let currentTag: @Sendable () -> String = { MainActor.assumeIsolated { tagged?.tag ?? "" } }

        // Esc は、録音中・認識待ち・実行中の間だけ受ける（それ以外は、Esc は、ほかのアプリへそのまま届く）。
        activity.onChange = { active in scheduler.onMain { escape.setActive(active) } }

        trigger.onPress = {
            activity.startRecording()
            emit(.recordingStarted, currentTag())
            recorder.start()
        }
        trigger.onRelease = {
            if activity.consumeCancelledRecording() { return }   // Esc で捨てた録音の「離した」
            let tag = currentTag()
            emit(.recognizing, tag)
            // 修飾キーを押している間は、Esc のホットキーを登録できない（実測）。離したあとに、登録し直す（修飾キーが離れるまでの間、数回試す）。
            for delay in rearmDelays {
                scheduler.afterOnMain(delay) { if activity.isActive { escape.setActive(true) } }
            }
            do {
                if let file = try recorder.stop() {
                    activity.stopRecording(queuedAudio: true)
                    tags.push(tag)
                    queue.push(.audio(file))
                    // 実行中（認識中を含む）の処理は、取りやめる：新しい依頼を、先に進める（確認の返事を待っているときは、取りやめない）
                    if activity.interruptForNewUtterance() { emit(.interrupted, tag) }
                } else {
                    activity.stopRecording(queuedAudio: false)
                    emit(.recordingEmpty, tag)
                }
            } catch {
                activity.stopRecording(queuedAudio: false)
                emit(.recordingFailed(error), tag)
            }
        }
        escape.onEscape = {
            switch activity.escape() {
            case .recording:
                recorder.discard()
                emit(.recordingDiscarded, currentTag())
            case .work:
                // 先に知らせる（読み上げを止める）。そのあとで、待っている処理を起こす。
                emit(.cancelling, "")
                queue.push(.cancel)   // 発話や確認の返事を待っている処理を起こす
            case .nothing:
                break
            }
        }

        Task { await self.consume() }
    }

    /// 列の音声を、1 つずつ、順に処理する（発話ごとに、取りやめの合図と `Task` を作る。Esc は、これらを止める）。
    @MainActor private func consume() async {
        while true {
            guard case let .audio(file) = await queue.next() else { continue }   // 待っている処理がないときの Esc の合図は、読み捨てる
            let tag = tags.pop()
            let token = CancelToken()
            activity.beginWork(token)
            let work = Task { await self.process(file, token, tag) }
            activity.setTask(work)
            await work.value
            activity.endWork()
        }
    }

    @MainActor private func process(_ file: URL, _ token: CancelToken, _ tag: String) async {
        do {
            guard let utterance = try await transcribe(file, token, tag) else { if !token.isSuperseded { emit(.recognitionCancelled, tag) }; return }
            await handler(utterance, token, { [self] in try await nextUtterance(token, tag) }, tag)
        } catch {
            if token.isSuperseded { return }   // 新しい発話に、取って代わられた：何も出さない（新しい発話の表示を、上書きしない）
            emit(token.isCancelled || error is CancellationError ? .recognitionCancelled : .recognitionFailed(error), tag)
        }
    }

    /// 列から取り出した音声を、文字にする。取りやめられていれば nil。
    @MainActor private func transcribe(_ file: URL, _ token: CancelToken, _ tag: String) async throws -> String? {
        activity.consumedAudio()
        // try?: 一時の録音ファイルの片付け。消せなくても、結果は変わらない
        defer { try? FileManager.default.removeItem(at: file) }
        if token.isCancelled { return nil }
        let text = try await transcriber.transcribe(file: file)
        if token.isCancelled { return nil }
        emit(.recognized(text), tag)
        return text
    }

    /// 次の発話（確認の返事にも使う）。取りやめられたら nil。
    /// `tag`：この発話（確認の前の依頼）の印。返事の録音の印は、取り出すときに引く（返事も、同じ列から来る）。
    @MainActor private func nextUtterance(_ token: CancelToken, _ tag: String) async throws -> String? {
        activity.beginAwaitingReply()   // 待っている間に来た発話は、新しい依頼ではなく、返事
        defer { activity.endAwaitingReply() }
        while true {
            switch await queue.next() {
            case .cancel: if token.isCancelled || Task.isCancelled { return nil }   // 前の処理の取りやめの合図は、読み捨てる。この待ち自体が取りやめられたら（ボタンが先に答えた）、やめる
            case let .audio(file): return try await transcribe(file, token, tags.pop())
            }
        }
    }
}

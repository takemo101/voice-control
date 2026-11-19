import AppKit
import Foundation
import VCCore

// MARK: - 差し替え口
// 差し替えるのは、実機（マイク・音声認識・キー）でしか動かない所だけ：録音・文字起こし・トリガー（`PushToTalkTrigger`）・Esc。

/// 音声ファイルを文字にする。実装は `FileTranscriber`。
public protocol Transcribing: Sendable {
    func transcribe(file url: URL) async throws -> String
    /// 文字と、**認識の確信度**（0〜1。分からなければ nil）。確信度のない実装（Whisper など）は、既定の実装（nil）のまま。
    func transcribeWithConfidence(file url: URL) async throws -> Transcription
}

extension Transcribing {
    public func transcribeWithConfidence(file url: URL) async throws -> Transcription {
        Transcription(text: try await transcribe(file: url), confidence: nil)
    }
}

/// 認識の結果：文字と、確信度（`Apple の SpeechTranscriber` が付ける。文字ごとの確信度を、文字数で重みづけて平均した値）。
public struct Transcription: Sendable, Equatable {
    public let text: String
    public let confidence: Double?
    public init(text: String, confidence: Double?) { self.text = text; self.confidence = confidence }

    /// 文字ごとの確信度（文字数と確信度）の、文字数で重みづけた平均。何もなければ nil。
    public static func meanConfidence(_ runs: [(characters: Int, confidence: Double)]) -> Double? {
        let total = runs.reduce(0) { $0 + $1.characters }
        guard total > 0 else { return nil }
        return runs.reduce(0.0) { $0 + $1.confidence * Double($1.characters) } / Double(total)
    }
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
/// - `tag`：この録音を始めたトリガーの印（`TaggedTrigger.tag`。トリガーが 1 つなら、空）。声の入力 が、声で頼む／音声入力を、トリガーで切り替えるのに使う。
public typealias UtteranceHandler = @MainActor @Sendable (_ utterance: String, _ cancel: CancelToken, _ next: @escaping NextUtterance, _ tag: String) async -> Void

/// **聞き取りに自信がないとき**（認識の確信度が `threshold` 未満）、実行の前に、聞こえた文を確かめる（聞き取りの確認。実験）。
/// `confirm` が false を返したら、その発話は、処理しない。声で頼む以外（音声入力など）は、`confirm` の側で、true を返してよい。
public struct Uncertainty: Sendable {
    public typealias Confirm = @MainActor @Sendable (_ text: String, _ confidence: Double, _ cancel: CancelToken, _ next: @escaping NextUtterance, _ tag: String) async -> Bool
    public let threshold: Double
    public let confirm: Confirm
    public init(threshold: Double, confirm: @escaping Confirm) { self.threshold = threshold; self.confirm = confirm }
}

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

/// 声の流れ（声の入力）の**調整**：トリガー（押した・離した）・録音・Esc・認識の待ち行列・発話ごとの処理の `Task`。
/// 状態の遷移は `VoiceActivity`、入力の列は `VoiceInputQueue`。スキル・画面の表示は、知らない（`UtteranceHandler`・`VoiceLoopEvent` の向こう側）。
///
/// **守る不変条件**（実際に起きた不具合）：
/// 1. **`run(onReady:)` は同期**で、`NSApplication.run()` の前に `await` を挟まない。`await` のあとの処理は、メインキューのブロックの中で動き、
///    そこから `run()` を呼ぶと、`DispatchQueue.main` に回した処理（画面の表示・長押しの判定の遅延）が動かない。呼ぶ側（声の入力）も、`run` の前に `await` しない
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
    private var consumeTask: Task<Void, Never>?
    private var stopped = false
    private let queue = VoiceInputQueue()
    /// 自信がないときの確認（なければ、確認しない）。`run` の前に、決める。
    public var uncertainty: Uncertainty?
    /// 新しい発話が来たとき、実行中の処理を、**取りやめずに**、順番を待たせるか（引数：新しい発話の印・実行中の処理の印）。なければ、いつも、取りやめる。会話の質問が、考えている間に、続けて話したときに使う。
    public var keepsRunning: (@Sendable (_ newTag: String, _ runningTag: String?) -> Bool)?
    /// 順番を待たせた発話が、**文字になった**とき（その場で、先に認識する）。`(文字・発話の印)`。空の文字も届く（聞き取れなかった）。順番が来たら、`inject` で、この流れに戻す。
    public var onDeferred: (@Sendable (_ text: String, _ tag: String) -> Void)?
    private let deferredRecognizer: DeferredRecognizer

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
        self.deferredRecognizer = DeferredRecognizer(transcriber: transcriber, emit: onEvent)
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

    /// 録音中・認識中・実行中・認識待ちの音声があるか（設定を反映するために、作り直してよいかの判断に使う）。
    public var isBusy: Bool { activity.isActive }

    /// 認識済みの発話を、この流れの処理に、戻す（順番待ちが、順番になった：会話）。ほかの処理が、動いていなければ、すぐ始まる。
    public func inject(_ text: String, tag: String) { queue.push(.text(text, tag: tag)) }

    /// 実行中の処理を、いますぐ、取りやめる（会話の「今すぐ送る」）。
    public func interruptRunning() { _ = activity.interruptRunning() }

    /// 止める：待ち行列の処理を終えて、このループを手放せるようにする（トリガー・Esc は、このループが手放されると、解放されて、登録が外れる）。
    /// **設定を変えたとき、作り直すために使う**。処理の最中は、呼ばない（`isBusy` が偽のときだけ）。止めたあとの `begin`・`run` は、できない。
    @MainActor public func stop() {
        stopped = true
        // キーの受け付けを、いますぐ外す（手放されるのを待たない。待つと、同じキーを登録し直すとき、`register(-9878)`＝登録済み、で失敗する）
        trigger.invalidate()
        escape.onEscape = nil
        escape.setActive(false)
        queue.push(.cancel)   // 待っている `consume` を起こして、終わらせる
    }

    /// アプリ（メニューバーの vc.app）用：イベントループは、アプリが回す。配線して、準備の表示を出して、戻る。**トリガーと Esc は、アプリが生きている間、手放さない**（`VoiceSession` が持つ。`VoiceLoop` 自身が、Esc を持つ）。ここにも `await` を足さない。
    @MainActor public func begin(onReady: () -> Void) {
        start()
        onReady()
    }

    /// トリガー・Esc の受け口を配線して、発話を順に処理する `Task` を始める（メインアクターの `Task`：呼び出し元の隔離を引き継ぐ）。
    @MainActor func start() {
        // 受け口のクロージャは、`self` ではなく、必要な部品だけを持つ（トリガー → クロージャ → `self` → トリガーの循環を作らない）。
        let activity = self.activity, queue = self.queue, recorder = self.recorder, escape = self.escape
        let emit = self.emit, scheduler = self.scheduler, rearmDelays = self.rearmDelays, tags = self.tags
        let keepsRunning = self.keepsRunning   // `run` の前に、決める（`self` を、クロージャに持たせない）
        let deferredRecognizer = self.deferredRecognizer
        deferredRecognizer.deliver = onDeferred
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
                    if let keep = keepsRunning, activity.defersNewUtterance(keepsRunning: { keep(tag, $0) }) {
                        // 会話の質問に、続けて話した：実行中の処理は、取りやめない。この発話は、**その場で、先に認識**して、順番待ちに入れる（順番が来たら、`inject` で戻る）
                        activity.stopRecording(queuedAudio: false)
                        deferredRecognizer.submit(file, tag: tag)
                    } else {
                        activity.stopRecording(queuedAudio: true)
                        tags.push(tag)
                        queue.push(.audio(file))
                        // 実行中（認識中を含む）の処理は、取りやめる：新しい依頼を、先に進める（確認の返事を待っているときは、取りやめない）
                        if activity.interruptForNewUtterance() { emit(.interrupted, tag) }
                    }
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
                deferredRecognizer.cancelAll()   // 先に認識していた、待たせた発話は、やめる（取りやめたあとに、動き出さないように）
                queue.push(.cancel)   // 発話や確認の返事を待っている処理を起こす
            case .nothing:
                break
            }
        }

        consumeTask = Task { await self.consume() }
    }

    /// 列の音声を、1 つずつ、順に処理する（発話ごとに、取りやめの合図と `Task` を作る。Esc は、これらを止める）。
    @MainActor private func consume() async {
        while !stopped {
            let input = await queue.next()
            if case let .text(text, tag) = input {   // 認識済みの発話（順番待ちが、順番になった）
                if stopped { break }
                let token = CancelToken()
                activity.beginWork(token, tag: tag)
                let work = Task {
                    let next: NextUtterance = { [self] in try await nextUtterance(token, tag) }
                    await self.handler(text, token, next, tag)
                }
                activity.setTask(work)
                await work.value
                activity.endWork()
                continue
            }
            guard case let .audio(file) = input else { continue }
            if stopped { try? FileManager.default.removeItem(at: file); break }   // 止めたあとに来た音声は、処理せず、捨てる   // 待っている処理がないときの Esc の合図は、読み捨てる
            let tag = tags.pop()
            let token = CancelToken()
            activity.beginWork(token, tag: tag)
            let work = Task { await self.process(file, token, tag) }
            activity.setTask(work)
            await work.value
            activity.endWork()
        }
    }

    @MainActor private func process(_ file: URL, _ token: CancelToken, _ tag: String) async {
        do {
            guard let heard = try await transcribe(file, token, tag) else { if !token.isSuperseded { emit(.recognitionCancelled, tag) }; return }
            let next: NextUtterance = { [self] in try await nextUtterance(token, tag) }
            // 聞き取りに自信がない：実行の前に、聞こえた文を確かめる（空の文は、確かめない：「聞き取れなかった」が、先に出る）
            if let uncertainty, let confidence = heard.confidence, confidence < uncertainty.threshold, !heard.text.isEmpty {
                let proceed = await uncertainty.confirm(heard.text, confidence, token, next, tag)
                if token.isCancelled || token.isSuperseded { return }
                if !proceed { return }
            }
            await handler(heard.text, token, next, tag)
        } catch {
            if token.isSuperseded { return }   // 新しい発話に、取って代わられた：何も出さない（新しい発話の表示を、上書きしない）
            emit(token.isCancelled || error is CancellationError ? .recognitionCancelled : .recognitionFailed(error), tag)
        }
    }

    /// 列から取り出した音声を、文字にする。取りやめられていれば nil。
    @MainActor private func transcribe(_ file: URL, _ token: CancelToken, _ tag: String) async throws -> Transcription? {
        activity.consumedAudio()
        // try?: 一時の録音ファイルの片付け。消せなくても、結果は変わらない
        defer { try? FileManager.default.removeItem(at: file) }
        if token.isCancelled { return nil }
        let heard = try await transcriber.transcribeWithConfidence(file: file)
        if token.isCancelled { return nil }
        emit(.recognized(heard.text), tag)
        return heard
    }

    /// 次の発話（確認の返事にも使う）。取りやめられたら nil。
    /// `tag`：この発話（確認の前の依頼）の印。返事の録音の印は、取り出すときに引く（返事も、同じ列から来る）。
    @MainActor private func nextUtterance(_ token: CancelToken, _ tag: String) async throws -> String? {
        activity.beginAwaitingReply()   // 待っている間に来た発話は、新しい依頼ではなく、返事
        defer { activity.endAwaitingReply() }
        while true {
            switch await queue.next() {
            case .cancel: if token.isCancelled || Task.isCancelled { return nil }   // 前の処理の取りやめの合図は、読み捨てる。この待ち自体が取りやめられたら（ボタンが先に答えた）、やめる
            case let .audio(file): return try await transcribe(file, token, tags.pop())?.text   // 確認の返事は、確信度を見ない
            case let .text(text, _): return text
            }
        }
    }
}

/// 順番を待たせた発話を、**その場で、先に認識する**（実行中の処理の裏で。認識は、1 つずつ、順に）。文字になったら、`deliver` へ渡す。Esc で、まだの認識は、やめる。
/// `@unchecked Sendable` の理由：可変な状態（`tokens`・`tail`・`deliver`）は、すべて `lock` で守る。
final class DeferredRecognizer: @unchecked Sendable {
    private let transcriber: Transcribing
    private let emit: @Sendable (VoiceLoopEvent, String) -> Void
    private let lock = NSLock()
    private var tokens: [UUID: CancelToken] = [:]
    private var tail: Task<Void, Never>?
    private var deliverHandler: (@Sendable (String, String) -> Void)?

    init(transcriber: Transcribing, emit: @escaping @Sendable (VoiceLoopEvent, String) -> Void) {
        self.transcriber = transcriber
        self.emit = emit
    }

    var deliver: (@Sendable (String, String) -> Void)? {
        get { lock.withLock { deliverHandler } }
        set { lock.withLock { deliverHandler = newValue } }
    }

    func submit(_ file: URL, tag: String) {
        let key = UUID(), token = CancelToken()
        let task: Task<Void, Never> = lock.withLock {
            let previous = tail
            tokens[key] = token
            let task = Task { [transcriber, emit] in
                await previous?.value   // 認識は、1 つずつ
                defer {
                    try? FileManager.default.removeItem(at: file)   // try?: 一時の録音ファイルの片付け。消せなくても、結果は変わらない
                    lock.withLock { tokens[key] = nil }
                }
                guard !token.isCancelled else { return }
                do {
                    let heard = try await transcriber.transcribeWithConfidence(file: file)
                    guard !token.isCancelled else { return }
                    emit(.recognized(heard.text), tag)
                    deliver?(heard.text, tag)
                } catch {
                    guard !token.isCancelled else { return }
                    emit(.recognitionFailed(error), tag)
                }
            }
            tail = task
            return task
        }
        _ = task
    }

    /// まだの認識を、すべてやめる（Esc）。
    func cancelAll() {
        let all = lock.withLock { Array(tokens.values) }
        all.forEach { $0.cancel() }
    }
}

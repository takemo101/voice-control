import Foundation

/// **ダブルタップ**の見分け（押した・離した・タップの時刻だけを見る。キー・マイクを知らない）。
/// - **押し続ける**：離すまで録音（従来どおり）。離したら `stop`。
/// - **ダブルタップ**（`doubleTapWindow` 以内に、短い押しを 2 回）：**手放しの録音**。黙ったら（`silence`）、または、もう一度タップしたら、`stop`。
/// 入力は 2 種類のトリガーで違う（`reportsTaps`）：
/// - 修飾キーだけ（Shift など）：短い押しは、「押した」にならず、**`tap`** だけが届く（タイピング中の Shift で、録音が始まらないように）。1 回目のタップでは、何も始めない。2 回目で、録音を始める（`beginHandsFreeAndStart`）。
/// - キーの組み合わせ（ctrl+opt+space など）：押した瞬間に、録音が始まる（話し出しを、削らない）。短く押して離したら、**離しを遅らせて**（`deferStop`）、2 回目を待つ。来なければ（`expire`）、止める（短すぎる録音は、捨てられる）。
public struct DoubleTapGesture: Sendable, Equatable {
    public enum Action: Sendable, Equatable { case none, start, stop, deferStop, beginHandsFree, beginHandsFreeAndStart }

    private enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        /// 1 回目の短い押しのあと、2 回目を待つ。`recording`：すでに録音が始まっている（キーの組み合わせ）。
        case pending(until: TimeInterval, recording: Bool)
        case handsFree
    }

    public let tapThreshold: TimeInterval
    public let doubleTapWindow: TimeInterval
    public let reportsTaps: Bool
    private var state = State.idle
    /// キーの組み合わせで、2 回目の押しが、手放しを始めた：その押しの「離し」は、終わりではない（ダブルタップの、後ろ半分）。
    private var swallowRelease = false

    public init(reportsTaps: Bool, tapThreshold: TimeInterval = 0.35, doubleTapWindow: TimeInterval = 0.5) {
        self.reportsTaps = reportsTaps; self.tapThreshold = tapThreshold; self.doubleTapWindow = doubleTapWindow
    }

    public var isHandsFree: Bool { state == .handsFree }

    /// キーを離しているのに、録音が続いている（手放し・2 回目を待っている〔キーの組み合わせ〕）。Esc で捨てたとき、離しを、こちらから伝える必要がある。
    public var isRecordingWithoutKey: Bool {
        switch state {
        case .handsFree, .pending(_, recording: true): return true
        default: return false
        }
    }

    /// 1 回目の短い押しのあと、2 回目を待っている。
    public var isPending: Bool {
        if case .pending = state { return true }
        return false
    }

    public mutating func press(at time: TimeInterval) -> Action {
        switch state {
        case .pending(let until, recording: true) where time <= until:
            state = .handsFree
            swallowRelease = true
            return .beginHandsFree   // 録音は、続いている
        case .handsFree, .holding:
            return .none   // 手放し中の押しは、離したときに終わる
        default:
            state = .holding(since: time)
            return .start
        }
    }

    public mutating func release(at time: TimeInterval) -> Action {
        switch state {
        case .holding(let since):
            if !reportsTaps, time - since < tapThreshold {
                state = .pending(until: time + doubleTapWindow, recording: true)
                return .deferStop
            }
            state = .idle
            return .stop
        case .handsFree:
            if swallowRelease { swallowRelease = false; return .none }
            state = .idle
            return .stop
        default:
            return .none
        }
    }

    /// 短く押して離した（`reportsTaps` のトリガーだけ）。
    public mutating func tap(at time: TimeInterval) -> Action {
        switch state {
        case .pending(let until, recording: false) where time <= until:
            state = .handsFree
            return .beginHandsFreeAndStart
        case .handsFree:
            state = .idle
            return .stop
        case .holding:
            return .none
        default:
            state = .pending(until: time + doubleTapWindow, recording: false)
            return .none
        }
    }

    /// 2 回目を待つ時間が、過ぎた。
    public mutating func expire() -> Action {
        guard case let .pending(_, recording) = state else { return .none }
        state = .idle
        return recording ? .stop : .none
    }

    /// 黙った（`SilenceEndpoint`）：手放しの録音なら、止める。
    public mutating func silence() -> Action {
        guard state == .handsFree else { return .none }
        state = .idle
        swallowRelease = false
        return .stop
    }

    /// 取りやめた（Esc）：状態を捨てる。
    public mutating func cancel() { state = .idle; swallowRelease = false }
}

/// 押している間だけ録音するトリガー（`PushToTalkTrigger`）に、**ダブルタップで、黙るまで録音する**動きを足す（手放し）。
/// - 押し続ける：従来どおり（離すと、録音を止めて、認識）。
/// - ダブルタップ：録音を続け、**黙ったら**（`SilenceEndpoint`）止めて、認識（声のあと 1.5 秒・声がなければ 8 秒・最長 30 秒）。もう一度タップするとすぐ認識。Esc で取りやめ。
/// 外には、キーの「押した・離した」だけを見せる（`VoiceLoop` は、手放しを知らない：離しを、遅らせるだけ）。
@MainActor public final class HandsFreeTrigger: PushToTalkTrigger {
    public var onPress: (@Sendable () -> Void)?
    public var onRelease: (@Sendable () -> Void)?
    /// 手放しの録音が、始まった（画面の案内を、替える）。
    public var onHandsFree: (@Sendable () -> Void)?

    private let inner: PushToTalkTrigger
    private var gesture: DoubleTapGesture
    private var endpoint: SilenceEndpoint?
    private let now: @Sendable () -> TimeInterval
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private var cancelTimer: (() -> Void)?
    private let flag = ActiveFlag()

    public var isHandsFree: Bool { gesture.isHandsFree }

    /// `schedule`：時間のあとに、1 回だけ呼ぶ（戻り値は、取りやめる手続き）。テストで、時計を、手で動かせるように差し替える。
    init(_ inner: PushToTalkTrigger, now: @escaping @Sendable () -> TimeInterval,
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void) {
        self.inner = inner
        self.gesture = DoubleTapGesture(reportsTaps: inner is TapReporting)
        self.now = now
        self.schedule = schedule
        inner.onPress = { [weak self] in MainActor.assumeIsolated { self?.innerPress() } }
        inner.onRelease = { [weak self] in MainActor.assumeIsolated { self?.innerRelease() } }
        if let tapper = inner as? TapReporting {
            tapper.onTap = { [weak self] in MainActor.assumeIsolated { self?.innerTap() } }
        }
    }

    public convenience init(_ inner: PushToTalkTrigger) {
        self.init(inner, now: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        })
    }

    private func innerPress() {
        apply(gesture.press(at: now()))
    }

    private func innerRelease() {
        apply(gesture.release(at: now()))
    }

    private func innerTap() {
        let action = gesture.tap(at: now())
        apply(action)
        if action == .none, gesture.isPending { waitForSecondTap() }   // 1 回目のタップ：2 回目を待つ（来なければ、なかったことにする）
    }

    private func apply(_ action: DoubleTapGesture.Action) {
        switch action {
        case .start:
            cancelPendingTimer()
            onPress?()
        case .stop:
            finish()
        case .deferStop:
            waitForSecondTap()   // キーの組み合わせ：離しを遅らせる。2 回目が来なければ、止める
        case .beginHandsFree:
            beginHandsFree()
        case .beginHandsFreeAndStart:
            onPress?()
            beginHandsFree()
        case .none:
            break
        }
    }

    /// 2 回目を待つ：来なければ、止める（録音が始まっていれば）／何もなかったことにする。
    private func waitForSecondTap() {
        cancelPendingTimer()
        cancelTimer = schedule(gesture.doubleTapWindow) { [weak self] in
            guard let self else { return }
            self.cancelTimer = nil
            if self.gesture.expire() == .stop { self.finish() }
        }
    }

    private func beginHandsFree() {
        cancelPendingTimer()
        endpoint = SilenceEndpoint()
        flag.set(true)
        onHandsFree?()
    }

    private func cancelPendingTimer() { cancelTimer?(); cancelTimer = nil }

    private func finish() {
        cancelPendingTimer()
        endpoint = nil
        flag.set(false)
        onRelease?()
    }

    // MARK: 黙ったか（音量は、音声のスレッドから来る）

    /// 録音中の音量（0〜1）を受ける。**音声のスレッドから呼ばれる**。手放しの録音でなければ、何もしない。
    public nonisolated func pushLevel(_ level: Float) {
        guard flag.value else { return }
        let time = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.feed(level: level, at: time) } }
    }

    func feed(level: Float, at time: TimeInterval) {
        guard var current = endpoint else { return }
        let verdict = current.feed(level: level, at: time)
        endpoint = current
        if case .stop = verdict, gesture.silence() == .stop { finish() }
    }

    /// `VoiceLoop` の出来事を受ける（メインのスレッドで届くもの）。Esc で録音を捨てたら、状態を解いて、離しを伝える（`ModeTrigger` の「押している」を解く）。
    /// 押している間の Esc は、何もしない（離したときに、`VoiceLoop` が、捨てた録音の「離した」として、読み捨てる）。
    public func observe(_ event: VoiceLoopEvent) {
        guard case .recordingDiscarded = event else { return }
        let keyIsUp = gesture.isRecordingWithoutKey
        gesture.cancel()
        cancelPendingTimer()
        if keyIsUp { finish() }
    }
}

/// 複数のトリガー（声で頼む・音声入力）の、手放しの録音を、まとめて扱う（マイクは 1 つ：同時に録音するのは、どれか 1 つ）。
@MainActor public final class HandsFreeGroup {
    public nonisolated static let hint = "話し終わると自動で認識します（もう一度タップすると、すぐ認識・Esc で取りやめ）"
    private let list = TriggerList()
    /// 手放しの録音が始まった（`tag`：`wrap` で渡した印）。
    public var onHandsFree: (@Sendable (_ tag: String) -> Void)?

    public init() {}

    /// `trigger` を包んで返す（`tag`：`ModeTrigger` の印）。
    public func wrap(_ trigger: PushToTalkTrigger, tag: String) -> HandsFreeTrigger {
        let wrapped = HandsFreeTrigger(trigger)
        wrapped.onHandsFree = { [weak self] in MainActor.assumeIsolated { self?.onHandsFree?(tag) } }
        list.append(wrapped)
        return wrapped
    }

    /// 録音中の音量を、全部へ渡す（**音声のスレッドから**）。
    public nonisolated func pushLevel(_ level: Float) {
        for trigger in list.snapshot() { trigger.pushLevel(level) }
    }

    public func observe(_ event: VoiceLoopEvent) {
        for trigger in list.snapshot() { trigger.observe(event) }
    }
}

/// トリガーの一覧（音声のスレッドと、メインが、読み書きする）。`@unchecked Sendable` の理由：`items` は、すべて `lock` で守る。
private final class TriggerList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HandsFreeTrigger] = []
    func append(_ trigger: HandsFreeTrigger) { lock.lock(); items.append(trigger); lock.unlock() }
    func snapshot() -> [HandsFreeTrigger] { lock.lock(); defer { lock.unlock() }; return items }
}

/// 手放しの録音の最中か（音声のスレッドが、読む）。`@unchecked Sendable` の理由：`flag` は、すべて `lock` で守る。
private final class ActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set(_ newValue: Bool) { lock.lock(); flag = newValue; lock.unlock() }
}

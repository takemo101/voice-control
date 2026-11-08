import Foundation

/// 「ちょっと押す」と「押し続ける」の見分け（押した・離したの時刻だけを見る。キー・マイクを知らない）。
/// - **押し続ける**（`tapThreshold` 以上）：離すまで録音（従来どおり）。離したら `stop`。
/// - **ちょっと押す**（`tapThreshold` 未満で離した）：**離しても止めない**（`beginHandsFree`）。黙ったら（`silence`）、または、もう一度押して離したら、`stop`。
public struct TapHoldGesture: Sendable, Equatable {
    public enum Action: Sendable, Equatable { case none, start, stop, beginHandsFree }

    public let tapThreshold: TimeInterval
    private var pressedAt: TimeInterval?
    public private(set) var handsFree = false

    public init(tapThreshold: TimeInterval = 0.5) { self.tapThreshold = tapThreshold }

    public mutating func press(at time: TimeInterval) -> Action {
        pressedAt = time
        return handsFree ? .none : .start   // 手放しの録音中の、2 回目の押しは、録音を始めない（離したときに、終わる）
    }

    public mutating func release(at time: TimeInterval) -> Action {
        guard let pressed = pressedAt else { return .none }   // 押していない（取りやめたあとの「離した」など）
        pressedAt = nil
        if handsFree { handsFree = false; return .stop }
        if time - pressed < tapThreshold { handsFree = true; return .beginHandsFree }
        return .stop
    }

    /// 黙った（`SilenceEndpoint`）：手放しの録音なら、止める。
    public mutating func silence() -> Action {
        guard handsFree else { return .none }
        handsFree = false
        pressedAt = nil
        return .stop
    }

    /// 取りやめた（Esc）：手放しの状態を捨てる。
    public mutating func cancel() { handsFree = false; pressedAt = nil }
}

/// 押している間だけ録音するトリガー（`PushToTalkTrigger`）に、**ちょっと押して離すと、黙るまで録音する**動きを足す（手放しの録音）。
/// - 押し続ける：従来どおり（離すと、録音を止めて、認識）。
/// - ちょっと押す（`tapThreshold` 未満）：録音を続け、**黙ったら**（`SilenceEndpoint`）止めて、認識（声のあと 1.5 秒・声がなければ 8 秒・最長 30 秒）。もう一度押して離すと、すぐ認識。Esc で取りやめ。
/// 外には、キーの「押した・離した」だけを見せる（`VoiceLoop` は、手放しを知らない：離しを、遅らせるだけ）。
@MainActor public final class HandsFreeTrigger: PushToTalkTrigger {
    public var onPress: (@Sendable () -> Void)?
    public var onRelease: (@Sendable () -> Void)?
    /// 手放しの録音が、始まった（画面の案内を、替える）。
    public var onHandsFree: (@Sendable () -> Void)?

    private let inner: PushToTalkTrigger
    private var gesture: TapHoldGesture
    private var endpoint: SilenceEndpoint?
    private let now: @Sendable () -> TimeInterval
    private let flag = ActiveFlag()

    public var isHandsFree: Bool { gesture.handsFree }

    public init(_ inner: PushToTalkTrigger, tapThreshold: TimeInterval = 0.5, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.inner = inner
        self.gesture = TapHoldGesture(tapThreshold: tapThreshold)
        self.now = now
        inner.onPress = { [weak self] in MainActor.assumeIsolated { self?.innerPress() } }
        inner.onRelease = { [weak self] in MainActor.assumeIsolated { self?.innerRelease() } }
    }

    private func innerPress() {
        if gesture.press(at: now()) == .start { onPress?() }
    }

    private func innerRelease() {
        switch gesture.release(at: now()) {
        case .stop: finish()
        case .beginHandsFree:
            endpoint = SilenceEndpoint()
            flag.set(true)
            onHandsFree?()
        case .none, .start: break
        }
    }

    private func finish() {
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

    /// `VoiceLoop` の出来事を受ける（メインのスレッドで届くもの）。Esc で録音を捨てたら、手放しの状態を解いて、離しを伝える（`ModeTrigger` の「押している」を解く）。
    public func observe(_ event: VoiceLoopEvent) {
        if case .recordingDiscarded = event, gesture.handsFree {
            gesture.cancel()
            finish()
        }
    }
}

/// 複数のトリガー（声で頼む・音声入力）の、手放しの録音を、まとめて扱う（マイクは 1 つ：同時に録音するのは、どれか 1 つ）。
@MainActor public final class HandsFreeGroup {
    public nonisolated static let hint = "話し終わると自動で認識します（もう一度押すと、すぐ認識・Esc で取りやめ）"
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

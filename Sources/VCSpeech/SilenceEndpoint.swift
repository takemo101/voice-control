import Foundation

/// 話し終わりの判定：録音中の音量（0〜1。`MicRecorder.level`：−60 dB 以下を 0、−12 dB 以上を 1）を、順に受けて、止めるかを返す。時計・マイクを知らない（時刻は、呼ぶ側が渡す）。
/// トリガーを押している間だけ録音する流れではなく、**撮った直後に自動で録音を始める流れ**（スクリーンショット）で、黙ったら止める。
/// 規則：
/// - 声の大きさ：**背景（これまでの滑らかにした音量の最小）+ 0.2 以上、かつ 0.35 以上**。一定の雑音（ファン）は、背景として引かれる。
/// - 声を聞いた：声の大きさが、合わせて 0.25 秒以上。ひと声（クリックなど）では、聞いたことにしない。
/// - 止める：聞いたあと、声の大きさが **1.5 秒**続かない（`silence`）／声を聞かないまま **8 秒**（`noSpeech`）／始めてから **30 秒**（`maxLength`）。
public struct SilenceEndpoint: Sendable {
    public enum Reason: Sendable, Equatable { case silenceAfterSpeech, noSpeech, tooLong }
    public enum Verdict: Sendable, Equatable { case listening, stop(Reason) }

    public let silence: TimeInterval, noSpeech: TimeInterval, maxLength: TimeInterval, minSpeech: TimeInterval
    private var start: TimeInterval?
    private var previous: TimeInterval?
    private var smoothed: Float?
    private var floor: Float = 1
    private var voiced: TimeInterval = 0
    private var lastVoiced: TimeInterval?

    public init(silence: TimeInterval = 1.5, noSpeech: TimeInterval = 8, maxLength: TimeInterval = 30, minSpeech: TimeInterval = 0.25) {
        self.silence = silence; self.noSpeech = noSpeech; self.maxLength = maxLength; self.minSpeech = minSpeech
    }

    public var heardSpeech: Bool { voiced >= minSpeech }

    /// 音量 `level` を、時刻 `time`（秒。単調に増える）で受ける。
    public mutating func feed(level: Float, at time: TimeInterval) -> Verdict {
        let begin = start ?? time
        start = begin
        let dt = min(0.2, max(0, time - (previous ?? time)))   // 受け取りが途切れても、その間を、声とは数えない
        previous = time
        let value = smoothed.map { $0 + 0.3 * (level - $0) } ?? level
        smoothed = value
        floor = min(floor, value)
        let threshold = max(0.35, floor + 0.2)
        if level >= threshold {
            voiced += dt
            if heardSpeech { lastVoiced = time }
        }
        if time - begin >= maxLength { return .stop(.tooLong) }
        if heardSpeech {
            if time - (lastVoiced ?? time) >= silence { return .stop(.silenceAfterSpeech) }
        } else if time - begin >= noSpeech {
            return .stop(.noSpeech)
        }
        return .listening
    }
}

import Foundation
import Testing
@testable import VCSpeech

/// 出力を消す・戻す回数を数える偽物。`alreadyMuted` なら、消さず（`nil`）、何も変えない。
private final class FakeOutput: OutputSilencing, @unchecked Sendable {   // 偽物：テストの数行。lock で守る
    private let lock = NSLock()
    private var _silenced = 0, _restored = 0
    let alreadyMuted: Bool
    init(alreadyMuted: Bool = false) { self.alreadyMuted = alreadyMuted }
    var silenced: Int { lock.lock(); defer { lock.unlock() }; return _silenced }
    var restored: Int { lock.lock(); defer { lock.unlock() }; return _restored }
    func silence() -> (@Sendable () -> Void)? {
        if alreadyMuted { return nil }
        lock.lock(); _silenced += 1; lock.unlock()
        return { [self] in lock.lock(); _restored += 1; lock.unlock() }
    }
}

/// 遅れて動く処理を、手で動かす（時間を待たない）。
private final class ManualClock: @unchecked Sendable {   // 偽物：テストの数行。lock で守る
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    var schedule: OutputMuter.Schedule { { [self] _, work in lock.lock(); pending.append(work); lock.unlock() } }
    func fireAll() { lock.lock(); let all = pending; pending = []; lock.unlock(); all.forEach { $0() } }
}

@Suite struct OutputMuterTests {
    private func make(alreadyMuted: Bool = false) -> (muter: OutputMuter, output: FakeOutput, clock: ManualClock) {
        let output = FakeOutput(alreadyMuted: alreadyMuted), clock = ManualClock()
        return (OutputMuter(backend: output, schedule: clock.schedule), output, clock)
    }

    @Test func mutesAfterTheDelayAndRestoresOnce() {
        let (muter, output, clock) = make()
        muter.engage()
        #expect(output.silenced == 0)          // 開始の合図（Pop）が鳴るまで、消さない
        clock.fireAll()
        #expect(output.silenced == 1)
        muter.restore(); muter.restore()       // 何回呼んでも、1 回だけ戻す
        #expect(output.restored == 1)
    }

    /// 消す前に離した（短い押下）：あとから、消してはいけない（消えたままになる）。
    @Test func aRestoreBeforeTheDelayCancelsTheMute() {
        let (muter, output, clock) = make()
        muter.engage()
        muter.restore()
        clock.fireAll()
        #expect(output.silenced == 0)
        #expect(output.restored == 0)
    }

    /// 前の録音の遅れた処理が、次の録音の途中に動いても、二重に消さない・早く戻さない。
    @Test func aStaleTimerFromAnEarlierRecordingDoesNothing() {
        let (muter, output, clock) = make()
        muter.engage(); muter.restore()        // 1 回目：消す前に離した
        muter.engage()                         // 2 回目
        clock.fireAll()                        // 1 回目の処理（古い）と 2 回目の処理が、動く
        #expect(output.silenced == 1)
        muter.restore()
        #expect(output.restored == 1)
    }

    /// もともと消音：触らない。戻しもしない（利用者の設定を変えない）。
    @Test func anOutputThatWasAlreadySilentIsLeftAlone() {
        let (muter, output, clock) = make(alreadyMuted: true)
        muter.engage()
        clock.fireAll()
        muter.restore()
        #expect(output.silenced == 0)
        #expect(output.restored == 0)
    }

    @Test func aDisabledMuterNeverTouchesTheOutput() {
        let clock = ManualClock()
        let muter = OutputMuter(backend: nil, schedule: clock.schedule)
        muter.engage(); clock.fireAll(); muter.restore()   // 何も起きない（落ちない）
    }

    /// 消している最中に取りやめられた（消す処理の途中で `restore()` が来た）ときも、消えたままにしない。
    @Test func aRestoreDuringTheSilencingStillRestores() {
        final class Slow: OutputSilencing, @unchecked Sendable {   // 偽物：消す処理の途中で、restore を呼ぶ
            var muter: OutputMuter?
            private(set) var restored = 0
            func silence() -> (@Sendable () -> Void)? {
                muter?.restore()
                return { [self] in restored += 1 }
            }
        }
        let backend = Slow(), clock = ManualClock()
        let muter = OutputMuter(backend: backend, schedule: clock.schedule)
        backend.muter = muter
        muter.engage()
        clock.fireAll()
        #expect(backend.restored == 1)
    }
}

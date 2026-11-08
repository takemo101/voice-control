import Foundation
import Testing
@testable import VCSpeech

/// ダブルタップで、黙るまで録音する（手放し）：押し続けるなら従来どおり・ダブルタップで手放し・もう一度タップすると、すぐ終わる・Esc で解ける。
@Suite struct DoubleTapGestureTests {
    // MARK: キーの組み合わせ（押した瞬間に、録音が始まる）

    @Test func chordHoldStopsWhenReleased() {
        var g = DoubleTapGesture(reportsTaps: false)
        #expect(g.press(at: 0) == .start)
        #expect(g.release(at: 2.0) == .stop && !g.isHandsFree)
    }

    @Test func chordQuickPressDefersTheStopAndASecondPressStartsHandsFree() {
        var g = DoubleTapGesture(reportsTaps: false)
        #expect(g.press(at: 0) == .start)
        #expect(g.release(at: 0.1) == .deferStop && g.isRecordingWithoutKey)
        #expect(g.press(at: 0.3) == .beginHandsFree && g.isHandsFree)   // 録音は、続いている（もう一度は始めない）
    }

    @Test func chordSingleQuickPressStopsWhenTheWindowPasses() {
        var g = DoubleTapGesture(reportsTaps: false)
        _ = g.press(at: 0); _ = g.release(at: 0.1)
        #expect(g.expire() == .stop && !g.isPending)
        #expect(g.press(at: 5) == .start)   // 窓のあとの押しは、新しい押し
    }

    @Test func chordSecondPressAfterTheWindowIsANewPress() {
        var g = DoubleTapGesture(reportsTaps: false, doubleTapWindow: 0.5)
        _ = g.press(at: 0); _ = g.release(at: 0.1)   // 窓は 0.6 まで
        #expect(g.press(at: 0.9) == .start && !g.isHandsFree)
    }

    // MARK: 修飾キー（短い押しは、タップとして届く）

    @Test func modifierFirstTapStartsNothingAndTheSecondStartsHandsFree() {
        var g = DoubleTapGesture(reportsTaps: true)
        #expect(g.tap(at: 0) == .none && g.isPending && !g.isRecordingWithoutKey)
        #expect(g.tap(at: 0.3) == .beginHandsFreeAndStart && g.isHandsFree)
    }

    @Test func modifierTapsFarApartAreTwoSingleTaps() {
        var g = DoubleTapGesture(reportsTaps: true, doubleTapWindow: 0.5)
        #expect(g.tap(at: 0) == .none)
        #expect(g.tap(at: 2) == .none && g.isPending && !g.isHandsFree)   // 2 回目は、新しい 1 回目
        #expect(g.expire() == .none && !g.isPending)                       // 録音は、始まっていないので、止めない
    }

    @Test func modifierHoldAfterATapIsAPlainHold() {
        var g = DoubleTapGesture(reportsTaps: true)
        _ = g.tap(at: 0)
        #expect(g.press(at: 0.2) == .start)
        #expect(g.release(at: 1.5) == .stop)
    }

    @Test func modifierQuickReleaseAfterTheHoldDelayIsNotATap() {
        var g = DoubleTapGesture(reportsTaps: true)
        #expect(g.press(at: 0) == .start)
        #expect(g.release(at: 0.1) == .stop && !g.isPending)   // 押した（長押しと判定された）あとの短い離しは、普通の押し
    }

    // MARK: 手放しの終わり

    @Test func silenceEndsHandsFreeOnlyWhenHandsFree() {
        var g = DoubleTapGesture(reportsTaps: true)
        #expect(g.silence() == .none)
        _ = g.tap(at: 0); _ = g.tap(at: 0.2)
        #expect(g.silence() == .stop && !g.isHandsFree)
    }

    @Test func tappingAgainEndsHandsFree() {
        var g = DoubleTapGesture(reportsTaps: true)
        _ = g.tap(at: 0); _ = g.tap(at: 0.2)
        #expect(g.tap(at: 3) == .stop && !g.isHandsFree)
    }

    @Test func pressingAndReleasingAgainEndsHandsFreeForAChord() {
        var g = DoubleTapGesture(reportsTaps: false)
        _ = g.press(at: 0); _ = g.release(at: 0.1); _ = g.press(at: 0.2)
        #expect(g.isHandsFree)
        #expect(g.release(at: 0.3) == .none && g.isHandsFree)   // ダブルタップの、後ろ半分の離し：終わりではない
        #expect(g.press(at: 3.0) == .none && g.isHandsFree)
        #expect(g.release(at: 3.1) == .stop && !g.isHandsFree)
    }

    @Test func cancelDropsEverything() {
        var g = DoubleTapGesture(reportsTaps: true)
        _ = g.tap(at: 0); _ = g.tap(at: 0.2)
        g.cancel()
        #expect(!g.isHandsFree && !g.isPending && g.release(at: 1) == .none)
    }
}

/// キーの代わりのトリガーと、手で動かす時計・タイマーで、`HandsFreeTrigger` のふるまいを確かめる。
@Suite @MainActor struct HandsFreeTriggerTests {
    private final class FakeChord: PushToTalkTrigger {
        var onPress: (@Sendable () -> Void)?
        var onRelease: (@Sendable () -> Void)?
        func press() { onPress?() }
        func release() { onRelease?() }
    }

    private final class FakeModifier: TapReporting {
        var onPress: (@Sendable () -> Void)?
        var onRelease: (@Sendable () -> Void)?
        var onTap: (@Sendable () -> Void)?
        func tap() { onTap?() }
        func press() { onPress?() }
        func release() { onRelease?() }
    }

    final class Counter: @unchecked Sendable {
        var time = 0.0, presses = 0, releases = 0, handsFree = 0
        var timers: [(delay: Double, fire: @MainActor () -> Void, cancelled: Bool)] = []
    }

    private func make(_ inner: PushToTalkTrigger) -> (HandsFreeTrigger, Counter) {
        let box = Counter()
        let trigger = HandsFreeTrigger(inner, now: { box.time }, schedule: { delay, work in
            let index = box.timers.count
            box.timers.append((delay, work, false))
            return { box.timers[index].cancelled = true }
        })
        trigger.onPress = { box.presses += 1 }
        trigger.onRelease = { box.releases += 1 }
        trigger.onHandsFree = { box.handsFree += 1 }
        return (trigger, box)
    }

    /// 待っているタイマーを、全部、鳴らす（取り消されたものは、鳴らさない）。
    private func fireTimers(_ box: Counter) {
        let pending = box.timers.filter { !$0.cancelled }
        box.timers.removeAll()
        pending.forEach { $0.fire() }
    }

    /// 声（0.5〜2 秒）のあと静か：手放しの録音が、離しを伝えるまで、音量を送る。
    private func speakThenSilence(_ trigger: HandsFreeTrigger, _ box: Counter) -> Double {
        var t = 0.0
        while t < 8, box.releases == 0 { trigger.feed(level: t >= 0.5 && t < 2 ? 0.7 : 0.05, at: t); t += 0.023 }
        return t
    }

    @Test func aChordHoldPassesPressAndReleaseThrough() {
        let key = FakeChord(); let (trigger, box) = make(key); defer { withExtendedLifetime(trigger) {} }
        box.time = 0; key.press(); box.time = 3; key.release()
        #expect(box.presses == 1 && box.releases == 1 && box.handsFree == 0)
    }

    @Test func aChordDoubleTapKeepsRecordingUntilSilence() {
        let key = FakeChord(); let (trigger, box) = make(key)
        box.time = 0; key.press(); box.time = 0.1; key.release()   // 1 回目：録音は始まり、離しは、遅れる
        #expect(box.presses == 1 && box.releases == 0)
        box.time = 0.3; key.press(); box.time = 0.4; key.release()   // 2 回目
        #expect(box.presses == 1 && box.handsFree == 1 && trigger.isHandsFree && box.releases == 0)
        fireTimers(box)   // 待ちのタイマーは、取り消されている：鳴らない
        #expect(box.releases == 0)
        let t = speakThenSilence(trigger, box)
        #expect(box.releases == 1 && !trigger.isHandsFree && t > 3.4 && t < 3.7)
    }

    @Test func aSingleChordTapStopsWhenTheWindowPasses() {
        let key = FakeChord(); let (trigger, box) = make(key); defer { withExtendedLifetime(trigger) {} }
        box.time = 0; key.press(); box.time = 0.1; key.release()
        #expect(box.releases == 0 && box.timers.count == 1 && box.timers[0].delay == 0.5)
        fireTimers(box)
        #expect(box.presses == 1 && box.releases == 1)   // 短すぎる録音は、受け手が捨てる
    }

    @Test func aModifierDoubleTapStartsRecordingAtTheSecondTap() {
        let key = FakeModifier(); let (trigger, box) = make(key)
        box.time = 0; key.tap()
        #expect(box.presses == 0 && box.timers.count == 1)   // 1 回目：何も始めない
        box.time = 0.3; key.tap()
        #expect(box.presses == 1 && box.handsFree == 1 && trigger.isHandsFree)
        fireTimers(box)
        #expect(box.releases == 0)
        _ = speakThenSilence(trigger, box)
        #expect(box.releases == 1)
    }

    @Test func aSingleModifierTapDoesNothing() {
        let key = FakeModifier(); let (trigger, box) = make(key)
        box.time = 0; key.tap()
        fireTimers(box)
        #expect(box.presses == 0 && box.releases == 0 && !trigger.isHandsFree)
    }

    @Test func tappingAgainEndsAModifierHandsFree() {
        let key = FakeModifier(); let (trigger, box) = make(key)
        box.time = 0; key.tap(); box.time = 0.2; key.tap()
        box.time = 4; key.tap()
        #expect(box.releases == 1 && !trigger.isHandsFree)
    }

    @Test func aModifierHoldStillWorksAsPushToTalk() {
        let key = FakeModifier(); let (trigger, box) = make(key); defer { withExtendedLifetime(trigger) {} }
        box.time = 0; key.press(); box.time = 2; key.release()
        #expect(box.presses == 1 && box.releases == 1 && box.handsFree == 0)
    }

    @Test func escapeFreesHandsFreeAndTellsTheLoopItEnded() {
        let key = FakeModifier(); let (trigger, box) = make(key)
        box.time = 0; key.tap(); box.time = 0.2; key.tap()
        trigger.observe(.recordingDiscarded)
        #expect(box.releases == 1 && !trigger.isHandsFree)
        // 押している間の Esc は、何もしない（離しは、キーから来る）
        box.time = 5; key.press()
        trigger.observe(.recordingDiscarded)
        #expect(box.releases == 1)
    }

    @Test func escapeDuringTheWaitForASecondChordTapEndsTheRecording() {
        let key = FakeChord(); let (trigger, box) = make(key)
        box.time = 0; key.press(); box.time = 0.1; key.release()   // 録音は続いている（離しは、遅れている）
        trigger.observe(.recordingDiscarded)
        #expect(box.releases == 1)
        fireTimers(box)   // タイマーは、取り消された
        #expect(box.releases == 1)
    }

    @Test func silenceBeforeHandsFreeDoesNothing() {
        let key = FakeChord(); let (trigger, box) = make(key)
        box.time = 0; key.press()
        for i in 0..<400 { trigger.feed(level: 0.05, at: Double(i) * 0.023) }
        #expect(box.releases == 0)
    }
}

import Foundation
import Testing
@testable import VCSpeech

/// 手放しの録音：押し続けるなら従来どおり・ちょっと押すと、黙るまで録音・もう一度押すとすぐ終わる・Esc で解ける。
@Suite struct HandsFreeTriggerTests {
    @Test func holdingStopsWhenReleased() {
        var g = TapHoldGesture(tapThreshold: 0.5)
        #expect(g.press(at: 0) == .start)
        #expect(g.release(at: 2.0) == .stop && !g.handsFree)
    }

    @Test func aQuickPressStartsHandsFreeAndSilenceStops() {
        var g = TapHoldGesture(tapThreshold: 0.5)
        #expect(g.press(at: 0) == .start)
        #expect(g.release(at: 0.2) == .beginHandsFree && g.handsFree)
        #expect(g.silence() == .stop && !g.handsFree)
        #expect(g.silence() == .none)   // 手放しでなければ、黙っても、何もしない
    }

    @Test func pressingAgainEndsHandsFreeWithoutStartingANewRecording() {
        var g = TapHoldGesture(tapThreshold: 0.5)
        _ = g.press(at: 0); _ = g.release(at: 0.1)
        #expect(g.press(at: 3) == .none)
        #expect(g.release(at: 3.1) == .stop && !g.handsFree)   // 2 回目は、短くても、終わり（もう一度、手放しに入らない）
    }

    @Test func aReleaseWithoutAPressIsIgnored() {
        var g = TapHoldGesture()
        #expect(g.release(at: 1) == .none)
        _ = g.press(at: 2); g.cancel()
        #expect(g.release(at: 2.1) == .none && !g.handsFree)
    }

    // MARK: キーの代わりのトリガーで、ふるまいを確かめる

    @MainActor private final class FakeKey: PushToTalkTrigger {
        var onPress: (@Sendable () -> Void)?
        var onRelease: (@Sendable () -> Void)?
        func press() { onPress?() }
        func release() { onRelease?() }
    }

    /// 時計・押した／離した・呼ばれた回数。
    @MainActor private final class Rig {
        let key = FakeKey()
        let box = Counter()
        var clock = 0.0
        lazy var trigger: HandsFreeTrigger = {
            let t = HandsFreeTrigger(key, tapThreshold: 0.5, now: { [box] in box.time })
            t.onPress = { [box] in box.presses += 1 }
            t.onRelease = { [box] in box.releases += 1 }
            t.onHandsFree = { [box] in box.handsFree += 1 }
            return t
        }()
        func at(_ t: Double) { box.time = t }
    }

    final class Counter: @unchecked Sendable {
        var time = 0.0, presses = 0, releases = 0, handsFree = 0
    }

    @MainActor @Test func aLongHoldPassesPressAndReleaseThrough() {
        let rig = Rig(); _ = rig.trigger
        rig.at(0); rig.key.press(); rig.at(3); rig.key.release()
        #expect(rig.box.presses == 1 && rig.box.releases == 1 && rig.box.handsFree == 0)
    }

    @MainActor @Test func aTapKeepsRecordingUntilSilence() {
        let rig = Rig(); let trigger = rig.trigger
        rig.at(0); rig.key.press(); rig.at(0.2); rig.key.release()
        #expect(rig.box.presses == 1 && rig.box.releases == 0 && rig.box.handsFree == 1 && trigger.isHandsFree)
        // 声（0.5〜2 秒）→ 静か：1.5 秒あと（3.5 秒）に、離しが伝わる
        var t = 0.0
        while t < 6, rig.box.releases == 0 { trigger.feed(level: t >= 0.5 && t < 2 ? 0.7 : 0.05, at: t); t += 0.023 }
        #expect(rig.box.releases == 1 && !trigger.isHandsFree && t > 3.4 && t < 3.7)
    }

    @MainActor @Test func aSecondPressEndsItImmediately() {
        let rig = Rig(); let trigger = rig.trigger
        rig.at(0); rig.key.press(); rig.at(0.1); rig.key.release()
        rig.at(2); rig.key.press()
        #expect(rig.box.presses == 1 && rig.box.releases == 0)   // 録音を、もう一度始めない
        rig.at(2.1); rig.key.release()
        #expect(rig.box.releases == 1 && !trigger.isHandsFree)
    }

    @MainActor @Test func escapeFreesTheHandsFreeStateAndTellsTheLoopItEnded() {
        let rig = Rig(); let trigger = rig.trigger
        rig.at(0); rig.key.press(); rig.at(0.1); rig.key.release()
        trigger.observe(.recordingDiscarded)
        #expect(rig.box.releases == 1 && !trigger.isHandsFree)
        // 手放しでないときの Esc（押している間）は、何もしない
        rig.at(5); rig.key.press()
        trigger.observe(.recordingDiscarded)
        #expect(rig.box.releases == 1)
    }

    @MainActor @Test func silenceBeforeAnyHandsFreeDoesNothing() {
        let rig = Rig(); let trigger = rig.trigger
        rig.at(0); rig.key.press()   // 押している間
        for i in 0..<400 { trigger.feed(level: 0.05, at: Double(i) * 0.023) }
        #expect(rig.box.releases == 0)
    }
}

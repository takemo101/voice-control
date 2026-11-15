import Foundation
import Testing
import VCCore
@testable import vc

/// 音声入力のあとの Enter：送る前の短い間は、取りやめ（Esc）・新しい依頼で、すぐ終わる（送信・実行は、取り消しにくい）。
@Suite struct DictationEnterTests {
    @Test func theDelayEndsNormallyWhenNothingCancelsIt() async {
        let started = Date()
        #expect(await DictationFlow.waitUnlessCancelled(0.12, CancelToken()))
        #expect(Date().timeIntervalSince(started) >= 0.1)
    }

    @Test func aCancelledOrSupersededTokenStopsTheWaitAtOnce() async {
        let cancelled = CancelToken(); cancelled.cancel()
        let started = Date()
        #expect(!(await DictationFlow.waitUnlessCancelled(5, cancelled)))
        let superseded = CancelToken(); superseded.supersede()
        #expect(!(await DictationFlow.waitUnlessCancelled(5, superseded)))
        #expect(Date().timeIntervalSince(started) < 1)   // 5 秒は、待たない
    }

    @Test func theDelayBeforeEnterIsShortEnoughToStayHandsFreeAndLongEnoughToCancel() {
        #expect(DictationFlow.enterDelay >= 0.5 && DictationFlow.enterDelay <= 1.5)
    }
}

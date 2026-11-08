import Testing
@testable import VCSpeech

/// 話し終わりの判定：黙ったら止める・途中の間では止めない・声のないときは、時間で止める・一定の雑音を声にしない。
@Suite struct SilenceEndpointTests {
    /// 0.023 秒ごとの音量の列（`levels`）を、時刻つきで渡して、最初に止まった時刻と理由を返す。
    private func run(_ endpoint: SilenceEndpoint = SilenceEndpoint(), _ level: (Double) -> Float, until: Double = 60) -> (time: Double, reason: SilenceEndpoint.Reason)? {
        var e = endpoint
        var t = 0.0
        while t <= until {
            if case let .stop(reason) = e.feed(level: level(t), at: t) { return (t, reason) }
            t += 0.023
        }
        return nil
    }

    @Test func stopsAfterSilenceFollowingSpeech() throws {
        // 0.5〜3 秒に声（0.7）、そのあとは静か（0.05）
        let result = try #require(run { $0 >= 0.5 && $0 < 3 ? 0.7 : 0.05 })
        #expect(result.reason == .silenceAfterSpeech)
        #expect(result.time > 4.4 && result.time < 4.7)   // 最後の声（3 秒）から 1.5 秒
    }

    @Test func aShortPauseInsideSpeechDoesNotStop() throws {
        // 声 → 1 秒の間 → 声 → 静か：間では止まらず、2 つ目の声の 1.5 秒あとに止まる
        let result = try #require(run { ($0 >= 0.5 && $0 < 2) || ($0 >= 3 && $0 < 4) ? 0.7 : 0.05 })
        #expect(result.reason == .silenceAfterSpeech && result.time > 5.4 && result.time < 5.7)
    }

    @Test func silenceAloneStopsAfterTheNoSpeechLimit() throws {
        let result = try #require(run { _ in 0.05 })
        #expect(result.reason == .noSpeech && result.time >= 8 && result.time < 8.2)
    }

    @Test func aSingleClickIsNotSpeech() throws {
        let result = try #require(run { $0 > 1 && $0 < 1.1 ? 0.9 : 0.05 })   // 0.1 秒だけ大きい
        #expect(result.reason == .noSpeech)
    }

    @Test func aSteadyNoiseIsNotSpeech() throws {
        let result = try #require(run { _ in 0.3 })   // ファンのような一定の音（0.35 に届かない）
        #expect(result.reason == .noSpeech)
        let loud = try #require(run { _ in 0.6 })   // 大きくても、一定なら背景として引かれる
        #expect(loud.reason == .noSpeech)
    }

    @Test func speechThatNeverPausesStopsAtTheMaximum() throws {
        // 声が上下し続ける（0.5 秒ごとに大小）：黙らないので、上限で止まる
        let result = try #require(run { Int($0 * 2) % 2 == 0 ? 0.8 : 0.45 })
        #expect(result.reason == .tooLong && result.time >= 30 && result.time < 30.2)
    }
}

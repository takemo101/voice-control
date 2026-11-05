import Testing
@testable import VCSpeech

/// 録音中の音量（波形用）：−60 dB 以下は 0、−12 dB 以上は 1、間は、なめらかに増える。
@Suite struct MicLevelTests {
    private func level(amplitude: Float, count: Int = 1_024) -> Float {
        let samples = [Float](repeating: amplitude, count: count)
        return samples.withUnsafeBufferPointer { MicRecorder.level(from: $0) }
    }

    @Test func silenceIsZeroAndLoudSpeechIsOne() {
        #expect(level(amplitude: 0) == 0)
        #expect(level(amplitude: 0.0005) == 0)
        #expect(level(amplitude: 0.5) == 1)
    }

    @Test func theLevelGrowsWithTheVolume() {
        let quiet = level(amplitude: 0.005), mid = level(amplitude: 0.03), loud = level(amplitude: 0.15)
        #expect(0 < quiet && quiet < mid && mid < loud && loud < 1)
    }

    @Test func anEmptyBufferIsZero() {
        #expect([Float]().withUnsafeBufferPointer { MicRecorder.level(from: $0) } == 0)
    }
}

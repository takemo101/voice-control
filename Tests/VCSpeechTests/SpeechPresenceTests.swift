import AVFoundation
import Foundation
import Testing
@testable import VCSpeech

/// 声のない録音（無音・一定の雑音）を、認識へ渡さない。声（短い「はい」も、雑音の中の声も）は、通す。
@Suite struct SpeechPresenceTests {
    private let rate = 16_000.0

    private func noise(_ seconds: Double, amplitude: Float, seed: UInt64 = 1) -> [Float] {
        var state = seed
        return (0..<Int(seconds * rate)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(1 << 24) - 0.5) * 2 * amplitude
        }
    }

    /// 声のような、音量の上がり下がり（4 Hz の波）をもつ音。
    private func speechLike(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            let envelope = Float(max(0, sin(2 * .pi * 4 * t)))
            return amplitude * envelope * Float(sin(2 * .pi * 220 * t))
        }
    }

    @Test func silenceAndSteadyNoiseHaveNoSpeech() {
        #expect(!SpeechPresence.analyze(samples: [Float](repeating: 0, count: 48_000), sampleRate: rate).hasSpeech)
        #expect(!SpeechPresence.analyze(samples: noise(3, amplitude: 0.02), sampleRate: rate).hasSpeech)
        #expect(!SpeechPresence.analyze(samples: noise(3, amplitude: 0.3), sampleRate: rate).hasSpeech)   // 大きくても、一定なら、声ではない
    }

    @Test func aShortSpokenWordInSilenceHasSpeech() {
        // 0.3 秒の声（「はい」ほどの長さ）を、前後 0.4 秒の無音ではさむ
        let pad = [Float](repeating: 0, count: Int(0.4 * rate))
        let word = speechLike(0.3, amplitude: 0.2)
        #expect(SpeechPresence.analyze(samples: pad + word + pad, sampleRate: rate).hasSpeech)
    }

    @Test func aClickShorterThanTheMinimumIsNotSpeech() {
        let pad = [Float](repeating: 0, count: Int(0.5 * rate))
        let click = [Float](repeating: 0.5, count: Int(0.04 * rate))
        #expect(!SpeechPresence.analyze(samples: pad + click + pad, sampleRate: rate).hasSpeech)
    }

    @Test func speechOverNoiseStillHasSpeech() {
        let background = noise(3, amplitude: 0.05)
        var mixed = background
        let voice = speechLike(1.2, amplitude: 0.15)
        for i in 0..<voice.count { mixed[Int(0.8 * rate) + i] += voice[i] }
        #expect(SpeechPresence.analyze(samples: mixed, sampleRate: rate).hasSpeech)
    }

    @Test func tooFewSamplesHaveNoSpeech() {
        #expect(!SpeechPresence.analyze(samples: [0.5, 0.5], sampleRate: rate).hasSpeech)
    }

    // MARK: GatedTranscriber

    private final class Spy: Transcribing, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func transcribe(file url: URL) async throws -> String { lock.withLock { count += 1 }; return "はい" }
    }

    private func wav(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// 声のない録音は、認識の実装を呼ばずに、空（聞き取れなかった）を返す。声のある録音は、認識へ渡す。
    @Test func gatedTranscriberSkipsTheEngineWhenThereIsNoSpeech() async throws {
        let spy = Spy()
        let gated = GatedTranscriber(spy)
        let silent = try wav([Float](repeating: 0, count: 32_000))
        defer { try? FileManager.default.removeItem(at: silent) }
        #expect(try await gated.transcribe(file: silent) == "")
        #expect(spy.calls == 0)

        let pad = [Float](repeating: 0, count: 6_400)
        let spoken = try wav(pad + speechLike(1.0, amplitude: 0.2) + pad)
        defer { try? FileManager.default.removeItem(at: spoken) }
        #expect(try await gated.transcribe(file: spoken) == "はい")
        #expect(spy.calls == 1)
    }
}

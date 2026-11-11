import AVFoundation
import Foundation

/// 録音に、声（話し声のような、音量の上がり下がり）があるか。**無音・一定の雑音だけの録音を、認識へ渡さない**ための判定（純粋な規則）。
/// 理由（測定。docs/verification.md「音声認識モデルの比較」）：声のない録音を渡すと、認識は、文を作る（Apple：「はい」〔20 件中 6 件〕、Whisper：「ご視聴ありがとうございました」〔20 件中 20 件〕）。
/// 確認の最中なら、「はい」と聞こえて、実行になりうる。
/// 規則：20 ミリ秒ごとの音量（dBFS）を出し、**下位 20%（背景）より 3 dB 以上高く、かつ −55 dBFS より大きい**フレームを「声のある」とする。声のあるフレームが、合わせて 0.12 秒以上あれば、声あり。
/// 一定の雑音（ファン・白色雑音）は、フレームごとの音量が揺れないので、どれも超えない。実際のマイクの背景は、約 −75 dBFS（測定：この Mac の内蔵のマイク）。
public enum SpeechPresence {
    public struct Verdict: Equatable, Sendable {
        public let hasSpeech: Bool
        /// 声のあるフレームの、合計の長さ（秒）。
        public let voicedSeconds: Double
        /// 背景（下位 20%）の音量（dBFS）。
        public let floorDB: Double
    }

    public static let frameSeconds = 0.02
    public static let riseDB = 3.0
    public static let absoluteFloorDB = -55.0
    public static let minimumVoicedSeconds = 0.12

    public static func analyze(samples: [Float], sampleRate: Double) -> Verdict {
        let frame = max(1, Int(sampleRate * frameSeconds))
        guard samples.count >= frame else { return Verdict(hasSpeech: false, voicedSeconds: 0, floorDB: -120) }
        var levels: [Double] = []
        levels.reserveCapacity(samples.count / frame)
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for i in start..<(start + frame) { sum += samples[i] * samples[i] }
            let rms = Double((sum / Float(frame)).squareRoot())
            levels.append(20 * log10(max(rms, 1e-9)))
            start += frame
        }
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.2)]
        let threshold = max(absoluteFloorDB, floor + riseDB)
        let voiced = Double(levels.filter { $0 > threshold }.count) * frameSeconds
        return Verdict(hasSpeech: voiced >= minimumVoicedSeconds, voicedSeconds: voiced, floorDB: floor)
    }

    /// 録音のファイルを読んで、判定する（先頭のチャンネルだけ）。読めなければ、投げる。
    public static func analyze(file url: URL) throws -> Verdict {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return Verdict(hasSpeech: false, voicedSeconds: 0, floorDB: -120)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return Verdict(hasSpeech: false, voicedSeconds: 0, floorDB: -120) }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return analyze(samples: samples, sampleRate: file.processingFormat.sampleRate)
    }
}

/// 認識の前に、声があるか確かめる。**声がなければ、認識に渡さず、空の文字（聞き取れなかった）を返す**（どの認識の実装にも、同じように効く）。
public struct GatedTranscriber: Transcribing {
    private let base: Transcribing
    public init(_ base: Transcribing) { self.base = base }

    public func transcribe(file url: URL) async throws -> String {
        guard try SpeechPresence.analyze(file: url).hasSpeech else { return "" }
        return try await base.transcribe(file: url)
    }

    public func transcribeWithConfidence(file url: URL) async throws -> Transcription {
        guard try SpeechPresence.analyze(file: url).hasSpeech else { return Transcription(text: "", confidence: nil) }
        return try await base.transcribeWithConfidence(file: url)
    }
}

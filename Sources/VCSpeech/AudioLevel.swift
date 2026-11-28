import AVFoundation

/// 取り込んだ音の大きさ（波形の表示用）。マイクの録音と、同じ尺度（0〜1）。
public enum AudioLevel {
    public static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        return MicRecorder.level(from: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}

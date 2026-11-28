import AVFoundation
import Foundation
import VCCore

/// マイクの音を、**ファイルに書かずに**、流す（文字起こしで、自分のマイクも並べる：SPEC F80。設定 `transcribeMic`）。`MicRecorder` は、録音して、ファイルにする。こちらは、音の塊を、そのまま渡すだけ。
/// 音は、メモリの上だけ。マイクの許可は、はじめて動かしたとき、OS が確かめる（音声入力と同じ）。
/// `@unchecked Sendable` の理由：`engine`・`continuation` は、`start`・`stop` だけが触る（呼び出し側が、直列にする）。
public final class MicStream: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    public init() {}

    public enum Failure: Error, CustomStringConvertible {
        case noInput
        public var description: String { tr("マイクの入力が、ありません") }
    }

    public func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // タップの塊は、使い回される：コピーして、渡す
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            if let source = buffer.floatChannelData, let target = copy.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) { target[channel].update(from: source[channel], count: Int(buffer.frameLength)) }
            }
            continuation.yield(copy)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }
        return stream
    }

    public func stop() {
        guard continuation != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}

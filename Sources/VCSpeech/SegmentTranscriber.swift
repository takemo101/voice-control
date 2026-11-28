import AVFoundation
import Foundation
import Speech
import VCCore

/// **文章ごとの**ストリーミング認識（Apple の `SpeechAnalyzer`。システム音声の文字起こし：SPEC F80）。確定した文は、1 件ずつ（`isFinal`）・確定前の文字は、途中経過として届く。
/// 音は、`feed` で渡す（どのスレッドからでもよい）。**言語のモデルが、入っていなければ、`start` が失敗する**（黙って何もしない、をしない：文字が出ない理由が、分からなくなる）。
/// `@unchecked Sendable` の理由：可変な状態は、すべて `lock` で守る。
public final class SegmentTranscriber: @unchecked Sendable {
    /// 認識の更新：確定した文（`isFinal`）か、確定前の文字（あとで変わる）。
    public struct Update: Sendable, Equatable {
        public let text: String
        public let isFinal: Bool
        public let date: Date
        /// 認識した音の位置（認識を始めてからの秒。字幕の時刻に使う）。分からなければ nil。
        public let range: ClosedRange<TimeInterval>?
        public init(text: String, isFinal: Bool, date: Date, range: ClosedRange<TimeInterval>? = nil) { self.text = text; self.isFinal = isFinal; self.date = date; self.range = range }
    }

    public enum Failure: Error, CustomStringConvertible {
        case modelMissing(String)
        case unsupportedFormat
        case failed(String)

        public var description: String {
            switch self {
            case let .modelMissing(locale): return tr("音声認識の言語（\(locale)）のモデルが、入っていません（設定 > 音声 で、言語を入れてください）")
            case .unsupportedFormat: return tr("音声の形式を、認識に渡せません")
            case let .failed(why): return tr("音声認識を始められません（\(why)）")
            }
        }
    }

    private let locale: Locale
    private let onUpdate: @Sendable (Update) -> Void
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var analyzer: SpeechAnalyzer?
    private var reader: Task<Void, Never>?

    public init(locale: Locale = Locale(identifier: "ja-JP"), onUpdate: @escaping @Sendable (Update) -> Void) {
        self.locale = locale
        self.onUpdate = onUpdate
    }

    /// 認識を始める。準備ができてから、戻る（その前の音は、`feed` が、読み捨てる）。
    public func start() async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        guard await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw Failure.modelMissing(locale.identifier(.bcp47))
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Failure.unsupportedFormat }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let reader = Task { [onUpdate] in
            do {
                for try await result in transcriber.results {
                    let start = result.range.start.seconds, end = result.range.end.seconds
                    let range: ClosedRange<TimeInterval>? = start.isFinite && end.isFinite && end >= start && start >= 0 ? start...end : nil
                    onUpdate(Update(text: String(result.text.characters), isFinal: result.isFinal, date: Date(), range: range))
                }
            } catch {}   // 認識が止まったら、更新が止まるだけ（終わり方は、`finish` が決める）
        }
        do { try await analyzer.start(inputSequence: stream) } catch {
            continuation.finish(); reader.cancel()
            throw Failure.failed("\(error)")
        }
        lock.withLock { self.continuation = continuation; self.targetFormat = format; self.analyzer = analyzer; self.reader = reader }
    }

    /// 音を渡す。すぐ戻る（変換して、流すだけ）。準備ができていなければ、読み捨てる。
    public func feed(_ buffer: AVAudioPCMBuffer) {
        let (continuation, target): (AsyncStream<AnalyzerInput>.Continuation?, AVAudioFormat?) = lock.withLock { (self.continuation, self.targetFormat) }
        guard let continuation, let target else { return }
        if buffer.format == target { continuation.yield(AnalyzerInput(buffer: buffer)); return }
        // 入力の形が変わったら、変換器を作り直す
        let converter: AVAudioConverter? = lock.withLock {
            if self.converter == nil || self.converter?.inputFormat != buffer.format { self.converter = AVAudioConverter(from: buffer.format, to: target) }
            return self.converter
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    /// 終わる：残りの認識を、確定させてから、戻る（最後の文を、落とさない）。
    public func finish() async {
        let (continuation, analyzer, reader): (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, Task<Void, Never>?) = lock.withLock {
            defer { self.continuation = nil; self.analyzer = nil; self.reader = nil }
            return (self.continuation, self.analyzer, self.reader)
        }
        continuation?.finish()
        if let analyzer {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { await analyzer.cancelAndFinishNow() }
        }
        await reader?.value
    }
}

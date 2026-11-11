import AVFoundation
import Foundation
import Speech

/// **録音中の文字（途中経過）**を出すための、リアルタイムの認識（`vc caption`。実験。F54）。録音の音（マイクの入力）を、そのまま `SpeechAnalyzer` に流して、**途中の文字**（確定前を含む）を、次々に返す。
/// 最終の文字は、いつもどおり、録音したファイルを認識した結果（`FileTranscriber`）：この認識は、**表示だけ**（結果・実行には使わない）。失敗しても、何も起きない（表示が出ないだけ）。音声は、この Mac の外へ出さない。
/// `@unchecked Sendable` の理由：可変な状態は、すべて `lock` で守る。`feed` は、音声のスレッドから呼ばれる。
public final class LiveCaptioner: @unchecked Sendable {
    private let locale: Locale
    private let onText: @Sendable (String) -> Void
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var analyzer: SpeechAnalyzer?
    private var task: Task<Void, Never>?
    private var finished = false

    /// `onText`：いまの文字（確定した文字 + 確定前の文字）。どのスレッドからでも呼ばれる。
    public init(locale: Locale = Locale(identifier: "ja-JP"), onText: @escaping @Sendable (String) -> Void) {
        self.locale = locale
        self.onText = onText
    }

    /// 認識を始める（準備は、非同期。準備ができるまでに届いた音は、読み捨てる：表示だけの認識なので）。
    public func start() {
        task = Task { [self] in await run() }
    }

    private func run() async {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])   // fastResults：録音の間に、途中の文字が届く（なければ、入力が終わってから、まとめて届く）
        // 言語のモデルが入っていなければ、何もしない（入れるのは、本来の認識の仕事：初回だけ長い）
        guard await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let alreadyFinished: Bool = lock.withLock {
            if finished { return true }
            self.continuation = continuation; self.targetFormat = format; self.analyzer = analyzer
            return false
        }
        if alreadyFinished { continuation.finish(); return }
        let reader = Task { [onText] in
            var confirmed = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal { confirmed += text; onText(confirmed) } else { onText(confirmed + text) }
                }
            } catch {}   // 表示だけの認識：止まったら、表示が止まるだけ
        }
        do { try await analyzer.start(inputSequence: stream) } catch { continuation.finish(); reader.cancel(); return }
        await reader.value
    }

    /// 準備ができて、音を受けられるか。
    public var isReady: Bool { lock.withLock { continuation != nil } }

    /// 音（マイクの入力）を渡す。音声のスレッドから呼ぶ：すぐ戻る（変換して、流すだけ）。準備ができていなければ、読み捨てる。
    public func feed(_ buffer: AVAudioPCMBuffer) {
        let (continuation, target): (AsyncStream<AnalyzerInput>.Continuation?, AVAudioFormat?) = lock.withLock { (self.continuation, self.targetFormat) }
        guard let continuation, let target else { return }
        let converted: AVAudioPCMBuffer?
        if buffer.format == target { converted = buffer } else {
            // 入力の形が変わったら、変換器を作り直す（録音の途中で、入力の機器が替わったとき）
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
            converted = output
        }
        if let converted { continuation.yield(AnalyzerInput(buffer: converted)) }
    }

    /// 終わる（録音が終わったとき）。残りの認識は、捨てる。
    public func finish() {
        let (continuation, analyzer): (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) = lock.withLock {
            finished = true
            defer { self.continuation = nil; self.analyzer = nil }
            return (self.continuation, self.analyzer)
        }
        continuation?.finish()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }
}

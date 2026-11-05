import AVFoundation
import CTranscribe
import Foundation

/// ネイティブ（transcribe.cpp）の呼び出しの失敗。
enum NativeSpeechError: Error, Equatable, CustomStringConvertible {
    case load(String)
    case run(String)
    var description: String {
        switch self {
        case let .load(reason): return "モデルを開けません（\(reason)）。壊れているか、形式が違います（vc model status --verify）"
        case let .run(reason): return "認識に失敗しました（\(reason)）"
        }
    }
}

private func describe(_ status: transcribe_status) -> String {
    "\(String(cString: transcribe_status_string(Int32(status.rawValue))))（\(status.rawValue)）"
}

/// ダウンロードしたモデル（GGUF）1 つを開いて、音声を文字にする。Metal（GPU）を使う。
/// ネイティブの規則：**1 つのモデルで、同時に実行できるのは 1 つ**。ロックで直列にする。
/// `@unchecked Sendable` の理由：`session` は、すべて `lock` の中で使う。
final class NativeRecognizer: @unchecked Sendable {
    private var session: OpaquePointer?
    private let lock = NSLock()

    /// ネイティブのログ（Metal の準備・モデルの読み込みの経過。1 回の起動で 100 行ほど）を止める。失敗は、状態コードで返る。**プロセスで 1 回だけ**（ネイティブの規則）。
    private static let silenceLogs: Void = { transcribe_log_set(nil, nil) }()

    init(modelURL: URL) throws {
        _ = Self.silenceLogs
        var load = transcribe_model_load_params()
        transcribe_model_load_params_init(&load)
        var parameters = transcribe_session_params()
        transcribe_session_params_init(&parameters)
        let status = transcribe_open(modelURL.path, &load, &parameters, &session)
        guard status.rawValue == 0, session != nil else { throw NativeSpeechError.load(describe(status)) }
    }

    /// モデルを手放す。**プロセスを終える前に呼ぶ**：開いたまま `exit` すると、ggml の Metal の後始末が abort する（実測）。何回呼んでもよい。
    func close() {
        lock.lock(); defer { lock.unlock() }
        if let session { transcribe_session_free(session) }
        session = nil
    }

    deinit { close() }

    /// 16 kHz・モノラル・float（-1〜1）の音声 1 つ（発話 1 つ）を、文字にする。
    func transcribe(_ samples: [Float], language: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty, let session else { return "" }
        var run = transcribe_run_params()
        transcribe_run_params_init(&run)
        let status = language.withCString { code -> transcribe_status in
            run.language = code
            return samples.withUnsafeBufferPointer { transcribe_run(session, $0.baseAddress, Int32($0.count), &run) }
        }
        guard status.rawValue == 0 else { throw NativeSpeechError.run(describe(status)) }
        return String(cString: transcribe_full_text(session))
    }
}

/// 音声ファイルを、16 kHz・モノラル・float にする（認識の入力）。
enum AudioSamples {
    static func mono16k(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw TranscriptionError.unreadableAudio(url.lastPathComponent) }
        guard file.length > 0 else { return [] }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TranscriptionError.unreadableAudio(url.lastPathComponent)
        }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw TranscriptionError.unreadableAudio(url.lastPathComponent) }
        var fed = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let failure { throw TranscriptionError.failed(failure.localizedDescription) }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// ダウンロードしたモデル（transcribe.cpp）で、音声ファイルを文字にする。音声は、この Mac の外へ出さない。
/// **モデルは、作るときに開く**（開けなければ、そこで投げる。使うときに、初めて失敗しない）。`close()` で手放す。
public final class LocalTranscriber: Transcribing, @unchecked Sendable {
    private let recognizer: NativeRecognizer
    public let language: String

    public init(modelFile: URL, language: String = "ja") throws {
        recognizer = try NativeRecognizer(modelURL: modelFile)
        self.language = language
    }

    public func close() { recognizer.close() }

    public func transcribe(file url: URL) async throws -> String {
        let samples = try AudioSamples.mono16k(from: url)
        do {
            let text = try recognizer.transcribe(samples, language: language)
            // 文末の句読点は、操作の判断に要らない（`FileTranscriber` と同じ）。
            return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。．.！？!?、")))
        } catch let error as NativeSpeechError {
            throw TranscriptionError.failed("\(error)")
        }
    }
}

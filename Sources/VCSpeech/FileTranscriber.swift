import AVFoundation
import Foundation
import Speech

public enum TranscriptionError: Error, Equatable, CustomStringConvertible {
    case unsupportedLocale(String)
    case unreadableAudio(String)
    case failed(String)
    /// 時間の上限（秒）に達した。止まったままの認識を、待ち続けない。
    case timedOut(stage: String, seconds: Int)

    public var description: String {
        switch self {
        case .unsupportedLocale(let id): return "この言語には対応していません（\(id)）"
        case .unreadableAudio(let name): return "録音を読めません（\(name)）"
        case .failed(let reason): return "文字にできませんでした（\(reason)）"
        case .timedOut(let stage, let seconds): return "\(stage)が \(seconds) 秒以内に終わらなかったので、やめました。もう一度、話してください"
        }
    }
}

/// Apple の `SpeechTranscriber`（オンデバイス）で、音声ファイルを文字にする。音声は、この Mac の外へ出さない。
/// 言語のモデルが未取得なら、OS の仕組みで取得する（初回だけ。Apple のサーバーから）。実装は meeting-analyzer の `AppleSpeechTranscriber` を、最小にしたもの。
/// **時間の上限がある**：用意（言語モデルの取得。初回だけ長い）と、認識（録音 1 回分）は、別々に測る。上限に達したら、止まった処理を放って、先へ進む
/// （取りやめ（Esc）にも、すぐ応える）。上限がないと、認識が止まったとき、そのあとの発話が、すべて待たされる。
/// - 認識の上限は、録音の長さで決める（`analysisTimeout(forSeconds:)`。測定：10 秒の録音が 0.2 秒）。固定の `analysisTimeout` を渡せば、それを使う。
/// - 認識が上限に達したら、**1 回だけ、やり直す**（新しい認識器で）。止まるのは時々で、次の 1 回は通ることが多かった（利用者の報告。原因は未特定）。
/// - 用意（対応言語の確認・言語モデルの取得の確認）は、**この実行の中で 1 回成功したら、以後は省く**（毎回の OS・通信の呼び出しを、止まる原因にしない）。
public struct FileTranscriber: Sendable {
    public let locale: Locale
    public let preparationTimeout: TimeInterval
    /// `nil` なら、録音の長さから決める。
    public let analysisTimeout: TimeInterval?

    public init(locale: Locale = Locale(identifier: "ja-JP"), preparationTimeout: TimeInterval = 300, analysisTimeout: TimeInterval? = nil) {
        self.locale = locale
        self.preparationTimeout = preparationTimeout
        self.analysisTimeout = analysisTimeout
    }

    /// 録音の長さ（秒）から決めた、認識の上限：長さの 3 倍 + 5 秒。短くても 10 秒は待つ。
    public static func analysisTimeout(forSeconds duration: TimeInterval) -> TimeInterval { max(10, duration * 3 + 5) }

    /// 用意が済んだ言語（この実行の中）。
    private static let prepared = PreparedLocales()
    private final class PreparedLocales: @unchecked Sendable {   // `@unchecked Sendable` の理由：`ids` を、すべて `lock` で守る
        private let lock = NSLock()
        private var ids: Set<String> = []
        func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
        func insert(_ id: String) { lock.withLock { _ = ids.insert(id) } }
    }

    /// 確定した認識結果をつないだ文字。何も聞き取れなければ空。
    public func transcribe(file url: URL) async throws -> String { try await transcribeWithConfidence(file: url).text }

    /// 文字と、確信度（文字ごとの確信度の、文字数で重みづけた平均）。
    public func transcribeWithConfidence(file url: URL) async throws -> Transcription {
        let wanted = locale.identifier(.bcp47)
        func open() throws -> AVAudioFile {
            do { return try AVAudioFile(forReading: url) } catch { throw TranscriptionError.unreadableAudio(url.lastPathComponent) }
        }
        let first = try open()
        let seconds = analysisTimeout ?? Self.analysisTimeout(forSeconds: Double(first.length) / max(1, first.processingFormat.sampleRate))
        if !Self.prepared.contains(wanted) {
            try await prepare(wanted)
            Self.prepared.insert(wanted)
        }
        // 認識が止まったときは、1 回だけ、やり直す（新しい認識器で。2 回目も止まれば、止まったことを伝える）
        func attempt(_ file: AVAudioFile) async throws -> Transcription {
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.transcriptionConfidence])
            return try await withDeadline(seconds: seconds) { try await Self.analyze(file, with: transcriber) }
        }
        do {
            return try await attempt(first)
        } catch is DeadlineExceeded {
            // やり直しは、読み直す（止まった 1 回目が、まだ、前のファイルを読んでいるかもしれない）
            do { return try await attempt(try open()) } catch is DeadlineExceeded { throw TranscriptionError.timedOut(stage: "音声の認識", seconds: Int(seconds)) }
        }
    }

    /// 対応言語の確認と、言語モデルの用意（未取得なら取得。初回だけ長い）。
    private func prepare(_ wanted: String) async throws {
        let supported: Bool
        do {
            // この確認も、止まりうる OS の呼び出しなので、用意と同じ上限の中で行う
            supported = try await withDeadline(seconds: preparationTimeout) { await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == wanted } }
        } catch is DeadlineExceeded {
            throw TranscriptionError.timedOut(stage: "対応言語の確認", seconds: Int(preparationTimeout))
        }
        guard supported else { throw TranscriptionError.unsupportedLocale(locale.identifier) }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        do {
            try await withDeadline(seconds: preparationTimeout) {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
            }
        } catch is DeadlineExceeded {
            throw TranscriptionError.timedOut(stage: "言語モデルの用意", seconds: Int(preparationTimeout))
        } catch is CancellationError {
            throw CancellationError()
        } catch { throw TranscriptionError.failed("言語モデルを用意できません: \(error.localizedDescription)") }
    }

    /// 1 回分の録音を、文字にする。取りやめられたら、認識を止める（止まったままで応えなくても、呼び出し側は、待たない）。
    private static func analyze(_ file: AVAudioFile, with transcriber: SpeechTranscriber) async throws -> Transcription {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let reader = Task { () -> Transcription in
            var all = AttributedString()
            for try await result in transcriber.results where result.isFinal { all += result.text }
            var runs: [(characters: Int, confidence: Double)] = []
            for run in all.runs { if let confidence = run.transcriptionConfidence { runs.append((all[run.range].characters.count, confidence)) } }
            return Transcription(text: String(all.characters), confidence: Transcription.meanConfidence(runs))
        }
        return try await withTaskCancellationHandler {
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                // 文末の句読点は、操作の判断に要らない（認識は「…して。」のように付ける）。
                let result = try await reader.value
                return Transcription(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。．.！？!?、"))), confidence: result.confidence)
            } catch {
                reader.cancel()
                if error is CancellationError { throw error }
                throw TranscriptionError.failed(error.localizedDescription)
            }
        } onCancel: {
            reader.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

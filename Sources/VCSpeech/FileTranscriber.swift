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
/// **時間の上限がある**：用意（言語モデルの取得。初回だけ長い）と、認識（録音 1 回分）は、別々に測る。上限に達したら、止まった処理を放置して、失敗を返す
/// （取りやめ（Esc）にも、すぐ応える）。上限がないと、認識が止まったとき、そのあとの発話が、すべて待たされる。
public struct FileTranscriber: Sendable {
    public let locale: Locale
    public let preparationTimeout: TimeInterval
    public let analysisTimeout: TimeInterval

    public init(locale: Locale = Locale(identifier: "ja-JP"), preparationTimeout: TimeInterval = 300, analysisTimeout: TimeInterval = 60) {
        self.locale = locale
        self.preparationTimeout = preparationTimeout
        self.analysisTimeout = analysisTimeout
    }

    /// 確定した認識結果をつないだ文字。何も聞き取れなければ空。
    public func transcribe(file url: URL) async throws -> String {
        let wanted = locale.identifier(.bcp47)
        let supported: Bool
        do {
            // この確認も、止まりうる OS の呼び出しなので、用意と同じ上限の中で行う
            supported = try await withDeadline(seconds: preparationTimeout) { await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == wanted } }
        } catch is DeadlineExceeded {
            throw TranscriptionError.timedOut(stage: "対応言語の確認", seconds: Int(preparationTimeout))
        }
        guard supported else { throw TranscriptionError.unsupportedLocale(locale.identifier) }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw TranscriptionError.unreadableAudio(url.lastPathComponent) }

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

        do {
            return try await withDeadline(seconds: analysisTimeout) { try await Self.analyze(file, with: transcriber) }
        } catch is DeadlineExceeded {
            throw TranscriptionError.timedOut(stage: "音声の認識", seconds: Int(analysisTimeout))
        }
    }

    /// 1 回分の録音を、文字にする。取りやめられたら、認識を止める（止まったままで応えなくても、呼び出し側は、待たない）。
    private static func analyze(_ file: AVAudioFile, with transcriber: SpeechTranscriber) async throws -> String {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let reader = Task { () -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
            return text
        }
        return try await withTaskCancellationHandler {
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                // 文末の句読点は、操作の判断に要らない（認識は「…して。」のように付ける）。
                return try await reader.value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。．.！？!?、")))
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

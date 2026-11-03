import AVFoundation
import Foundation
import Speech

public enum TranscriptionError: Error, Equatable {
    case unsupportedLocale(String)
    case unreadableAudio(String)
    case failed(String)
}

/// Apple の `SpeechTranscriber`（オンデバイス）で、音声ファイルを文字にする。音声は、この Mac の外へ出さない。
/// 言語のモデルが未取得なら、OS の仕組みで取得する（初回だけ。Apple のサーバーから）。実装は meeting-analyzer の `AppleSpeechTranscriber` を、最小にしたもの。
public struct FileTranscriber: Sendable {
    public let locale: Locale
    public init(locale: Locale = Locale(identifier: "ja-JP")) { self.locale = locale }

    /// 確定した認識結果をつないだ文字。何も聞き取れなければ空。
    public func transcribe(file url: URL) async throws -> String {
        let supported = await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        guard supported else { throw TranscriptionError.unsupportedLocale(locale.identifier) }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw TranscriptionError.unreadableAudio(url.lastPathComponent) }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
        } catch { throw TranscriptionError.failed("言語モデルを用意できません: \(error.localizedDescription)") }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let reader = Task { () -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
            return text
        }
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
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }
}

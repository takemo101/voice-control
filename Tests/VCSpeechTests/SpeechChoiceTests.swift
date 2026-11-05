import AVFoundation
import Foundation
import Testing
import VCCore
@testable import VCSpeech

/// 使う音声認識の選び方：知らない名前は、黙って Apple にしない。取得していないモデルは、開かない。
@Suite struct SpeechChoiceTests {
    @Test func parsesAppleAndCatalogModelsAndRejectsUnknownNames() {
        #expect(SpeechChoice.parse("apple") == .success(.apple))
        guard case let .success(.local(model)) = SpeechChoice.parse("whisper-large-v3-turbo") else { Issue.record("知っているモデルを読めない"); return }
        #expect(model.id == "whisper-large-v3-turbo")
        #expect(SpeechChoice.parse("whisper-large-v3-turbo-typo") == .failure(.init(id: "whisper-large-v3-turbo-typo")))
        #expect(SpeechChoice.parse("") == .failure(.init(id: "")))
    }

    /// 設定が、知らない名前なら、理由を返す（既定に倒さない）。なければ Apple。
    @Test func settingsMapToAChoiceOrAReason() {
        var settings = Settings()
        #expect(settings.speechChoice == .success(.apple))
        settings.stt = "nope"
        #expect(settings.speechChoice == .failure(.init(id: "nope")))
        settings.stt = "whisper-large-v3-turbo"
        #expect(settings.speechChoice.map(\.id) == .success("whisper-large-v3-turbo"))
    }

    private func model(named name: String) -> SpeechModel {
        let spec = ModelSpec(name: name, baseURL: URL(string: "https://example.invalid/")!, files: [ModelFile(name: "m.gguf", bytes: 4, sha256: "")])
        return SpeechModel(id: name, name: name, summary: "", spec: spec)
    }

    /// 取得していないモデルは、黙って Apple に切り替えずに、失敗する（理由は、取得の手順を含む）。
    @Test func anUninstalledModelFailsToOpen() {
        let missing = model(named: "missing-\(UUID().uuidString)")
        do {
            _ = try SpeechEngine.make(.local(missing))
            Issue.record("取得していないモデルを開けてしまった")
        } catch let failure as SpeechEngine.Failure {
            guard case .modelMissing = failure else { Issue.record("別の失敗: \(failure)"); return }
            #expect("\(failure)".contains("vc model download \(missing.id)"))
        } catch { Issue.record("別のエラー: \(error)") }
    }

    /// モデルのファイルが壊れていれば（形式が違う）、使うときではなく、開くときに、失敗する。
    @Test func aCorruptModelFileFailsToOpenNotToTranscribe() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString).gguf")
        try Data("not a model".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try LocalTranscriber(modelFile: file) }
    }

    /// 録音のファイル（44.1 kHz・ステレオ）を、認識の入力（16 kHz・モノラル）にする：長さが保たれる。
    @Test func audioIsConvertedToMono16k() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(44_100)   // 1 秒
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = 0.3 * Float(sin(2 * .pi * 440 * Double(i) / 44_100)) } }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let samples = try AudioSamples.mono16k(from: url)
        #expect(abs(samples.count - 16_000) < 400)
        #expect((samples.map { abs($0) }.max() ?? 0) > 0.1)
    }
}

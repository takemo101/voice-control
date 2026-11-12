import AVFoundation
import Foundation
import Testing
@testable import VCSpeech

/// 集めた文字（音声のスレッドから、足される）。
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ text: String) { lock.lock(); items.append(text); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// 録音中の文字（途中経過）：マイクの入力と同じように、小さな塊で音を流すと、途中の文字が、次々に出て、最後は全文になる。Speech の言語モデルが要る：CI の VM では、動かさない。
@Suite(.timeLimit(.minutes(2))) struct LiveCaptionerTests {
    private func speechFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("caption-\(UUID().uuidString).aiff")
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say"); say.arguments = ["-v", "Kyoko", "-o", url.path, text]
        try say.run(); say.waitUntilExit()
        return url
    }

    @Test(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "Speech の言語モデルが、CI の VM にない"))
    func partialTextArrivesWhileFeedingAndEndsWithTheWholeSentence() async throws {
        let file = try speechFile("コーデックスにこの画面を見せて、エラーの意味を聞いて")
        defer { try? FileManager.default.removeItem(at: file) }
        let seen = Seen()
        let captioner = LiveCaptioner { seen.add($0.text) }
        captioner.start()
        var waited = 0
        while !captioner.isReady && waited < 400 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }   // 準備を待つ（最大 20 秒）
        #expect(captioner.isReady)
        let audio = try AVAudioFile(forReading: file)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1024))
        while audio.framePosition < audio.length {   // マイクの入力と同じ：1024 フレームずつ
            try audio.read(into: buffer, frameCount: 1024)
            captioner.feed(buffer)
        }
        var polls = 0
        while !(seen.values.last ?? "").contains("エラーの意味") && polls < 200 { try await Task.sleep(nanoseconds: 50_000_000); polls += 1 }   // 最大 10 秒
        captioner.finish()
        #expect(seen.values.count >= 2)   // 途中経過が、何度か出る（1 回だけではない）
        #expect((seen.values.last ?? "").contains("コーデックス") && (seen.values.last ?? "").contains("エラーの意味"))
    }

    @Test func feedingBeforeReadyOrAfterFinishDoesNothing() throws {
        let captioner = LiveCaptioner { _ in Issue.record("文字は、出ないはず") }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)); buffer.frameLength = 1024
        captioner.feed(buffer)   // 始める前
        captioner.finish()
        captioner.feed(buffer)   // 終わったあと
        #expect(!captioner.isReady)
    }
}

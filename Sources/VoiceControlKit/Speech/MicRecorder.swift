import AVFoundation
import Foundation

public enum MicError: Error { case writeFailed(String), noInput }

/// マイクの音を、ファイルへ録音する（ホットキー・ウェイクワードの前の、最小の入力）。音声は、この Mac の外へ出さない。
public final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    // 書き込みは、音声のスレッドで起きる。`stop()` が、止めてから読む。
    private var writeError: String?

    public init() {}

    /// マイクの許可。未決なら、macOS の確認を出す（この関数を呼ぶのは、利用者が `vc listen` を実行したときだけ）。
    public static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(to url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw MicError.noInput }
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            do { try self?.file?.write(from: buffer) } catch { self?.writeError = "\(error)" }
        }
        try engine.start()
    }

    public func stop() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        if let writeError { throw MicError.writeFailed(writeError) }
    }
}

/// ホットキーの「押した → 離した」で、1 回分の録音をする。`start()` の失敗は、`stop()` で返す。
public final class RecordingSession: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: MicRecorder?
    private var file: URL?
    private var startError: Error?

    public init() {}

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard recorder == nil else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vc-\(UUID().uuidString).caf")
        let r = MicRecorder()
        do { try r.start(to: url); recorder = r; file = url; startError = nil } catch { startError = error }
    }

    /// 録音したファイル。録音が始まっていなければ `nil`（始めに失敗していれば、その失敗を投げる）。
    public func stop() throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let startError { self.startError = nil; throw startError }
        guard let r = recorder, let url = file else { return nil }
        recorder = nil; file = nil
        try r.stop()
        return url
    }
}

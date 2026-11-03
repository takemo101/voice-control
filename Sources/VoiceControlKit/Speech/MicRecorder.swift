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

    /// マイクの許可。未決なら、macOS の確認を出して、答えを待つ（この関数を呼ぶのは、利用者が `vc listen` を実行したときだけ）。
    /// **同期**にしてある：`await` を挟むと、そのあとの処理は、メインキューのブロックの中で動き、続けて呼ぶ `NSApplication.run()` が、
    /// `DispatchQueue.main` に回した処理（画面の表示・長押しの判定の遅延）を動かせない。
    public static func authorize() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            let box = GrantBox()
            AVCaptureDevice.requestAccess(for: .audio) { granted in box.granted = granted; semaphore.signal() }
            semaphore.wait()
            return box.granted
        default: return false
        }
    }

    private final class GrantBox: @unchecked Sendable { var granted = false }

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

    /// 録音を捨てる（Esc で取りやめたとき）。録音したファイルは、消す。文字にはしない。
    public func discard() {
        lock.lock(); defer { lock.unlock() }
        startError = nil
        guard let r = recorder, let url = file else { return }
        recorder = nil; file = nil
        // try?: 録音を捨てるときの片付け。失敗すると一時ファイルが残る（セッションは、どちらでも録音なしの状態になる）
        try? r.stop()
        try? FileManager.default.removeItem(at: url)
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

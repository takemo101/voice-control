import AVFoundation
import Foundation

public enum MicError: Error { case writeFailed(String), noInput }

/// マイクの音を、ファイルへ録音する（ホットキー・ウェイクワードの前の、最小の入力）。音声は、この Mac の外へ出さない。
/// `@unchecked Sendable` の理由：音声のスレッドと呼び出し側の両方が触る `file`・`writeError` は、`lock` で守る。
/// `engine` は `start`・`stop` だけが触る（呼び出し側が直列にする：`RecordingSession` はロック、`vc listen` の Enter 録音は単独のスレッド）。
/// `lock` を持ったまま `engine` を止めない（止める側が、音声のスレッドを待つため、タップと詰まる）。
public final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    // 書き込みは、音声のスレッドで起きる。`stop()` が、止めてから読む。
    private var writeError: String?
    /// 録音中の音量（0〜1。約 23 ミリ秒ごと。**音声のスレッドから呼ばれる**）。画面の波形用。音声そのものは、渡さない。
    private var levelHandler: (@Sendable (Float) -> Void)?

    public init() {}

    public func setLevelHandler(_ handler: (@Sendable (Float) -> Void)?) { lock.withLock { levelHandler = handler } }

    /// 音量（dBFS）を、波形に使う 0〜1 にする：−60 dB 以下を 0、−12 dB 以上を 1（声の大きさの範囲）。
    static func level(from samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 60) / 48))
    }

    /// マイクの許可の状態（**聞かない**：確認のダイアログを出さない。`vc doctor` が使う）。
    public enum Permission: Equatable, Sendable { case granted, notDetermined, denied }
    public static var permission: Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied   // denied・restricted
        }
    }

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

    /// `@unchecked Sendable` の理由：`granted` は、ロックで守る（通知のスレッドが書き、呼び出し側が、セマフォを待ってから読む）。
    private final class GrantBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var granted: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    public func start(to url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw MicError.noInput }
        let newFile = try AVAudioFile(forWriting: url, settings: format.settings)
        lock.withLock { file = newFile }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let handler: (@Sendable (Float) -> Void)? = lock.withLock {
                do { try self.file?.write(from: buffer) } catch { self.writeError = "\(error)" }
                return self.levelHandler
            }
            if let handler, let channel = buffer.floatChannelData?[0] {
                handler(Self.level(from: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
            }
        }
        try engine.start()
    }

    public func stop() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let error: String? = lock.withLock { file = nil; return writeError }
        if let error { throw MicError.writeFailed(error) }
    }
}

/// ホットキーの「押した → 離した」で、1 回分の録音をする。`start()` の失敗は、`stop()` で返す。
/// `@unchecked Sendable` の理由：可変な状態（`recorder`・`file`・`startError`）は、すべて `lock` で守る。
public final class RecordingSession: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: MicRecorder?
    private var file: URL?
    private var startError: Error?
    private var levelHandler: (@Sendable (Float) -> Void)?

    public init() {}

    /// 録音中の音量（0〜1）を受け取る（画面の波形用）。次の `start()` から効く。音声のスレッドから呼ばれる。
    public func setLevelHandler(_ handler: (@Sendable (Float) -> Void)?) { lock.lock(); levelHandler = handler; lock.unlock() }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard recorder == nil else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vc-\(UUID().uuidString).caf")
        let r = MicRecorder()
        r.setLevelHandler(levelHandler)
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

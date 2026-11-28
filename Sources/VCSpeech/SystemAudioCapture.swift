import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VCCore

/// システム音声（Mac から出ている音）の取り込み（SPEC F80。参考：meeting-analyzer の `SystemAudioCapture`）。**文字起こし専用**：スキル・会話・コマンドへは、回さない。
/// 音は、メモリの上だけで扱い、**書き出さない**。権限は、画面収録（ScreenCaptureKit が、音の取り込みに、要求する）。**権限の要求は、`start` が OS に対して行う**：利用者が、開始の操作をした中だけで、呼ぶ。
public enum SystemAudioError: Error, CustomStringConvertible, Sendable {
    case permissionDenied
    case noDisplay
    case appNotFound([String])
    case failed(String)

    public var description: String {
        switch self {
        case .permissionDenied: return tr("画面収録が許可されていません（システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 で、このアプリを許可してください）")
        case .noDisplay: return tr("画面が見つかりません")
        case let .appNotFound(ids): return tr("選んだアプリが起動していません：\(ids.joined(separator: "、"))")
        case let .failed(why): return tr("システム音声の取り込みを始められません（\(why)）")
        }
    }
}

/// 取り込める（音を出せる）アプリの 1 つ。
public struct CaptureApp: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}

/// システム音声を取り込んでいるか（プロセス全体の 1 つの旗）。**取り込んでいる間は、録音中の「ほかの音を消す」を、しない**：出力を消すと、取り込む音も、消える（`OutputMuter.engage` が見る）。
public enum SystemAudioActivity {
    private static let state = LockedCount()
    public static var isActive: Bool { state.value > 0 }
    static func begin() { state.add(1) }
    static func end() { state.add(-1) }

    private final class LockedCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add(_ delta: Int) { lock.withLock { count = max(0, count + delta) } }
    }
}

/// どの音を取り込むか。
public enum SystemAudioTarget: Sendable, Equatable {
    /// Mac から出ている音すべて。
    case allApps
    /// 選んだアプリ（bundle ID）の音だけ。
    case apps([String])
}

/// `@unchecked Sendable`：`stream`・`continuation` は、`lock` の下だけで読み書きする（音の塊は、OS のキューで届き、`start`・`stop` は、別のスレッドから呼ばれる）。`counted` は、`activeLock` の下。
public final class SystemAudioCapture: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let queue = DispatchQueue(label: "voice-control.system-audio")
    private let activeLock = NSLock()
    private var counted = false

    public override init() { super.init() }

    /// 画面収録の許可の確認だけ（要求はしない）。
    public static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// 取り込める（音を出せる）アプリの一覧。許可が、まだなら、OS の確認が出る。
    public static func availableApps() async throws -> [CaptureApp] {
        let content = try await shareableContent()
        return content.applications.filter { !$0.bundleIdentifier.isEmpty && !$0.applicationName.isEmpty }
            .map { CaptureApp(bundleID: $0.bundleIdentifier, name: $0.applicationName) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private static func shareableContent() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw SystemAudioError.permissionDenied }
    }

    /// 取り込みを始める。音の塊が、届いた順に流れる（`stop` か、OS が止めると、終わる）。**このアプリ自身の音は、除く**（読み上げなどが、混ざらない）。
    public func start(target: SystemAudioTarget) async throws -> AsyncStream<AVAudioPCMBuffer> {
        let content = try await Self.shareableContent()
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }
        let filter: SCContentFilter
        switch target {
        case .allApps:
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case let .apps(ids):
            let apps = content.applications.filter { ids.contains($0.bundleIdentifier) }
            guard !apps.isEmpty else { throw SystemAudioError.appNotFound(ids) }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // 映像は使わない：最小の大きさ・最小の頻度で、負荷を減らす
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let (audio, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // 受け口は、始める前に、置く（始まってすぐに届く音を、取りこぼさない）
        lock.withLock { self.continuation = continuation }
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            lock.withLock { self.continuation = nil }
            continuation.finish()
            throw SystemAudioError.failed(error.localizedDescription)
        }
        lock.withLock { self.stream = stream }
        markActive(true)
        return audio
    }

    public func stop() async {
        let (stream, continuation) = lock.withLock { () -> (SCStream?, AsyncStream<AVAudioPCMBuffer>.Continuation?) in
            defer { self.stream = nil; self.continuation = nil }
            return (self.stream, self.continuation)
        }
        try? await stream?.stopCapture()   // try?: 止まっているものを、止めようとして、失敗しても、よい
        continuation?.finish()
        markActive(false)
    }

    /// `SystemAudioActivity` を、この取り込みの分だけ、数える（始まりと終わりを、1 回ずつ）。
    private func markActive(_ on: Bool) {
        activeLock.lock(); defer { activeLock.unlock() }
        guard on != counted else { return }
        counted = on
        if on { SystemAudioActivity.begin() } else { SystemAudioActivity.end() }
    }
}

extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        lock.withLock { continuation }?.yield(buffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { continuation }?.finish()
        markActive(false)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

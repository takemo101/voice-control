import CoreAudio
import Foundation

/// 出力（スピーカー・ヘッドホン）を、いったん消すための口。**消せたら、元に戻す手続きを返す**（すでに消えている・消せない出力は `nil`：何も変えていないので、戻さない）。
public protocol OutputSilencing: Sendable {
    func silence() -> (@Sendable () -> Void)?
}

/// 録音している間、ほかの音（再生中の音楽・通話・通知）を消す。マイクが、その音を拾って、認識を妨げるのを防ぐ。
/// 守ること：
/// - **元の状態にしか戻さない**：消したのが自分のときだけ、戻す。もともと消音だったなら、触らない（戻して、利用者の設定を変えない）。
/// - **遅れて消す**（`engage(after:)`）：録音の開始の合図（Pop）を、聞こえるようにする。消す前に、`restore()` が呼ばれたら、消さない（世代で見分ける）。
/// - `restore()` は、何回呼んでもよい。
/// `@unchecked Sendable` の理由：可変な状態（`generation`・`undo`）は、すべて `lock` で守る。
public final class OutputMuter: @unchecked Sendable {
    public typealias Schedule = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private let backend: OutputSilencing?
    private let schedule: Schedule
    private let lock = NSLock()
    private var generation = 0
    private var undo: (@Sendable () -> Void)?

    /// `backend` が `nil` なら、何もしない（`--no-mute`）。
    public init(backend: OutputSilencing?, schedule: @escaping Schedule = { delay, work in DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work) }) {
        self.backend = backend
        self.schedule = schedule
    }

    /// 実際の出力（CoreAudio）を消す。終了時（`exit`）にも、戻す。
    public static let system: OutputMuter = {
        let muter = OutputMuter(backend: CoreAudioOutput())
        atexit { OutputMuter.system.restore() }
        return muter
    }()

    /// 何もしない。
    public static let disabled = OutputMuter(backend: nil)

    /// `delay` 秒あとに、消す。そのあいだに `restore()` が呼ばれたら、消さない。
    public func engage(after delay: TimeInterval = 0.3) {
        guard let backend else { return }
        lock.lock(); generation += 1; let mine = generation; lock.unlock()
        schedule(delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = self.generation != mine || self.undo != nil
            self.lock.unlock()
            if stale { return }
            // 消す処理（CoreAudio）は、ロックの外で行う（戻す手続きを受け取ってから、ロックを取り直す）
            let undo = backend.silence()
            self.lock.lock()
            if self.generation == mine, self.undo == nil { self.undo = undo; self.lock.unlock() } else { self.lock.unlock(); undo?() }
        }
    }

    /// 消していたら、戻す。まだ消していなければ、これから消すのを、取りやめる。
    public func restore() {
        lock.lock()
        generation += 1
        let undo = self.undo
        self.undo = nil
        lock.unlock()
        undo?()
    }
}

/// 既定の出力デバイスを、消音（なければ、音量 0）にする。
struct CoreAudioOutput: OutputSilencing {
    func silence() -> (@Sendable () -> Void)? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        // もともと消音なら、何も変えない（音量にも触らない）。戻すものがない
        if Self.isMuted(device) { return nil }
        // 1) 消音のスイッチ（マスター）。2) なければ、左右のチャンネルの消音。3) なければ、音量を 0 に。
        if let undo = Self.mute(device, elements: [kAudioObjectPropertyElementMain]) ?? Self.mute(device, elements: [1, 2]) { return undo }
        return Self.zeroVolume(device)
    }

    /// マスター・左右のどれかが、消音になっているか。
    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        [kAudioObjectPropertyElementMain, 1, 2].contains { element in
            let a = address(kAudioDevicePropertyMute, element: element)
            guard isSettable(device, a) || hasProperty(device, a) else { return false }
            return (get(device, a, UInt32(0)) ?? 0) != 0
        }
    }

    private static func hasProperty(_ device: AudioDeviceID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        return AudioObjectHasProperty(device, &a)
    }

    private static func address(_ selector: AudioObjectPropertySelector, element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func isSettable(_ device: AudioDeviceID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        guard AudioObjectHasProperty(device, &a) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
    }

    private static func get<T>(_ device: AudioDeviceID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = a, value = initial, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func set<T>(_ device: AudioDeviceID, _ a: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var a = a, value = value
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    /// `elements` のうち、消せて、いま消音でないものを、消音にする。もともと消音のものには、触らない。1 つも消せなければ `nil`。
    private static func mute(_ device: AudioDeviceID, elements: [UInt32]) -> (@Sendable () -> Void)? {
        var changed: [AudioObjectPropertyAddress] = []
        for element in elements {
            let a = address(kAudioDevicePropertyMute, element: element)
            guard isSettable(device, a), let muted = get(device, a, UInt32(0)), muted == 0 else { continue }
            if set(device, a, UInt32(1)) { changed.append(a) }
        }
        guard !changed.isEmpty else { return nil }
        let toRestore = changed
        return { for a in toRestore { _ = set(device, a, UInt32(0)) } }
    }

    /// 消音のスイッチがない出力：音量を 0 にして、元の音量を覚えておく。
    private static func zeroVolume(_ device: AudioDeviceID) -> (@Sendable () -> Void)? {
        var saved: [(AudioObjectPropertyAddress, Float32)] = []
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [UInt32] {
            let a = address(kAudioDevicePropertyVolumeScalar, element: element)
            guard isSettable(device, a), let volume = get(device, a, Float32(0)), volume > 0 else { continue }
            if set(device, a, Float32(0)) { saved.append((a, volume)) }
        }
        guard !saved.isEmpty else { return nil }
        let toRestore = saved
        return { for (a, volume) in toRestore { _ = set(device, a, volume) } }
    }
}

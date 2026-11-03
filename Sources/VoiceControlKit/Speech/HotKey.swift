import AppKit
import Carbon.HIToolbox
import Foundation

/// 全体で効くホットキー（押した・離した）。Carbon の `RegisterEventHotKey` を使う：入力監視の許可が要らない。
/// アプリのイベントループ（`NSApplication.run()`）が回っているときだけ届く。
public final class HotKey: @unchecked Sendable {
    public var onPress: (@Sendable () -> Void)?
    public var onRelease: (@Sendable () -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    public enum Failure: Error { case register(OSStatus) }

    /// 既定：control + option + space。
    public init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(controlKey | optionKey)) throws {
        var spec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            switch GetEventKind(event) {
            case UInt32(kEventHotKeyPressed): me.onPress?()
            case UInt32(kEventHotKeyReleased): me.onRelease?()
            default: break
            }
            return noErr
        }, 2, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw Failure.register(status) }
        let id = EventHotKeyID(signature: OSType(0x7663_6b79), id: 1)   // 'vcky'
        let reg = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard reg == noErr else { throw Failure.register(reg) }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// 修飾キー（Shift など）だけを押し続ける間、押している扱いにする。通常の入力（大文字を打つための Shift）で、誤って始まらないよう：
/// - 他のキーなしで、`holdDelay` 秒（既定 0.35）押し続けたときだけ、「押した」。
/// - それまでに他のキーが押されたら、取りやめ。
/// 全体のキー入力を見る（`NSEvent` のグローバルモニタ）ので、**アクセシビリティの許可**が要る（`AXIsProcessTrusted`）。許可がなければ、何も届かない。
/// アプリのイベントループ（`NSApplication.run()`）が回っているときだけ届く。
public final class ModifierHold: @unchecked Sendable {
    public var onPress: (@Sendable () -> Void)?
    public var onRelease: (@Sendable () -> Void)?
    private let modifier: NSEvent.ModifierFlags
    private let holdDelay: TimeInterval
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var active = false

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public init(modifier: NSEvent.ModifierFlags = .shift, holdDelay: TimeInterval = 0.35) {
        self.modifier = modifier
        self.holdDelay = holdDelay
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in self?.flagsChanged(e) }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in self?.cancelPending() }) { monitors.append(m) }
    }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    private func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if flags == modifier {
            guard pending == nil, !active else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.pending != nil else { return }
                self.pending = nil
                self.active = true
                self.onPress?()
            }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: item)
        } else {
            cancelPending()
            if active { active = false; onRelease?() }
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}

/// 「押している間だけ聞く」の入り口。`HotKey`（キーの組み合わせ）と `ModifierHold`（修飾キーの長押し）。
public protocol PushToTalkTrigger: AnyObject {
    var onPress: (@Sendable () -> Void)? { get set }
    var onRelease: (@Sendable () -> Void)? { get set }
}
extension HotKey: PushToTalkTrigger {}
extension ModifierHold: PushToTalkTrigger {}

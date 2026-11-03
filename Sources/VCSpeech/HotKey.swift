import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// 全体で効くホットキー（押した・離した）。Carbon の `RegisterEventHotKey` を使う：入力監視の許可が要らない。
/// アプリのイベントループ（`NSApplication.run()`）が回っているときだけ届く。
/// メインスレッド専用：Carbon のアプリのイベントは、メインスレッドで届く（ハンドラは `assumeIsolated` で入る）。
@MainActor public final class HotKey {
    public var onPress: (@Sendable () -> Void)?
    public var onRelease: (@Sendable () -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// このホットキーの番号。複数のホットキー（トリガーと Esc など）が、互いのイベントを受けないようにする。
    private let id: UInt32
    private static let lastID = OSAllocatedUnfairLock<UInt32>(initialState: 0)

    private static func nextID() -> UInt32 { lastID.withLock { $0 += 1; return $0 } }

    public enum Failure: Error { case register(OSStatus) }

    /// 既定：control + option + space。
    public init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(controlKey | optionKey)) throws {
        var spec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        id = Self.nextID()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                var pressed = EventHotKeyID()
                let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard got == noErr, pressed.id == me.id else { return OSStatus(eventNotHandledErr) }   // ほかのホットキーのイベントは、通す
                switch GetEventKind(event) {
                case UInt32(kEventHotKeyPressed): me.onPress?()
                case UInt32(kEventHotKeyReleased): me.onRelease?()
                default: break
                }
                return noErr
            }
        }, 2, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw Failure.register(status) }
        let hotKeyID = EventHotKeyID(signature: OSType(0x7663_6b79), id: id)   // 'vcky'
        let reg = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard reg == noErr else { throw Failure.register(reg) }
    }

    isolated deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// 修飾キー（Shift など）だけを押し続ける間、押している扱いにする。通常の入力（大文字を打つための Shift）で、誤って始まらないよう：
/// - 他のキーなしで、`holdDelay` 秒（既定 0.35）押し続けたときだけ、「押した」。
/// - それまでに他のキーが押されたら、取りやめ。
/// 全体のキー入力を見る（`NSEvent` のグローバルモニタ）ので、**アクセシビリティの許可**が要る（`AXIsProcessTrusted`）。許可がなければ、何も届かない。
/// アプリのイベントループ（`NSApplication.run()`）が回っているときだけ届く。
/// メインスレッド専用：`NSEvent` のグローバルモニタと、遅延（`DispatchQueue.main`）は、メインスレッドで届く（`assumeIsolated` で入る）。
@MainActor public final class ModifierHold {
    public var onPress: (@Sendable () -> Void)?
    public var onRelease: (@Sendable () -> Void)?
    private let modifier: NSEvent.ModifierFlags
    private let holdDelay: TimeInterval
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var active = false

    nonisolated public static var isTrusted: Bool { AXIsProcessTrusted() }

    public init(modifier: NSEvent.ModifierFlags = .shift, holdDelay: TimeInterval = 0.35) {
        self.modifier = modifier
        self.holdDelay = holdDelay
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in MainActor.assumeIsolated { self?.flagsChanged(e) } }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in MainActor.assumeIsolated { self?.cancelPending() } }) { monitors.append(m) }
    }

    isolated deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    private func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if flags == modifier {
            guard pending == nil, !active else { return }
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pending != nil else { return }
                    self.pending = nil
                    self.active = true
                    self.onPress?()
                }
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
@MainActor public protocol PushToTalkTrigger: AnyObject {
    var onPress: (@Sendable () -> Void)? { get set }
    var onRelease: (@Sendable () -> Void)? { get set }
}
extension HotKey: PushToTalkTrigger {}
extension ModifierHold: PushToTalkTrigger {}

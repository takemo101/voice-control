import AppKit
import Carbon.HIToolbox
import Foundation

/// Esc キーで「取りやめ」を受ける。**有効にしている間だけ**受ける（普段は、Esc に触れない）。メインスレッド専用（`@MainActor`）：Carbon のアプリのイベントも、`NSEvent` のグローバルモニタも、メインスレッドで届く（`assumeIsolated` で入る）。
/// 受け方は 2 つ（実測にもとづく）：
/// - **グローバルのキー監視**（アクセシビリティの許可があるとき）：Shift などを**押している間**の Esc も、受けられる。Esc は、ほかのアプリにも届く（横取りしない）。
/// - **Carbon のホットキー**（許可は要らない）：Esc だけ、または Shift・Control・Option つき。受けると、Esc は、ほかのアプリへ届かない。
///   **修飾キーを押している間に登録すると、そのあとの Esc が、届かなくなる**（実測）。そのため、修飾キーがすべて離されているときだけ登録する
///   （押している間に `setActive(true)` を呼んだら、離したあとに、もう一度呼ぶ）。
@MainActor public final class EscapeKey: Sendable {
    public var onEscape: (@Sendable () -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var monitor: Any?

    public init() {}

    public var isActive: Bool { !refs.isEmpty || monitor != nil }

    fileprivate func fire() { onEscape?() }

    /// Esc の受け付けを、始める・やめる。始める方は、何度呼んでもよい（足りない受け方だけを足す）。受け付けられなければ false。
    @discardableResult
    public func setActive(_ active: Bool) -> Bool {
        if !active {
            unregisterHotKeys()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            return true
        }
        if monitor == nil, AXIsProcessTrusted() {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let isEscape = event.keyCode == UInt16(kVK_Escape)
                if isEscape { MainActor.assumeIsolated { self?.fire() } }
            }
        }
        // 不変条件（`VoiceLoop` のコメントの 3）：修飾キーを押している間は、Carbon のホットキーを登録しない。離したあとの `setActive(true)`（`VoiceLoop` が呼び直す）で登録する。
        let modifiersDown = !NSEvent.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
        if refs.isEmpty, !modifiersDown { registerHotKeys() }
        return isActive
    }

    private static let signature = OSType(0x7663_6573)   // 'vces'

    private func registerHotKeys() {
        var spec = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                var pressed = EventHotKeyID()
                let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard got == noErr, pressed.signature == EscapeKey.signature else { return OSStatus(eventNotHandledErr) }   // ほかのホットキー（トリガー）のイベントは、通す
                Unmanaged<EscapeKey>.fromOpaque(userData).takeUnretainedValue().fire()
                return noErr
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return }
        let bits: [UInt32] = [UInt32(shiftKey), UInt32(controlKey), UInt32(optionKey)]
        for combination in 0..<(1 << bits.count) {
            let modifiers = bits.enumerated().reduce(UInt32(0)) { $0 | (combination >> $1.offset & 1 == 1 ? $1.element : 0) }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: EscapeKey.signature, id: UInt32(combination + 1))
            if RegisterEventHotKey(UInt32(kVK_Escape), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref { refs.append(ref) }
        }
    }

    private func unregisterHotKeys() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    isolated deinit {
        unregisterHotKeys()
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

import AppKit
import Foundation

/// クリップボード（ペーストボード）への、小さな口。実装は `SystemPasteboard`。テストでは、偽物に替える。
@MainActor public protocol PasteboardAccess: AnyObject {
    /// 中身が変わるたびに増える数（ほかのアプリが、コピーしたかを知る）。
    var changeCount: Int { get }
    /// 中身を、すべて（型ごとのデータ）、控える。
    func snapshot() -> [[String: Data]]
    /// 文字を書く。**クリップボードの履歴アプリが、記録しない印**（`org.nspasteboard.TransientType`・`ConcealedType`）つき。
    func writeTransient(text: String)
    /// 控えを、元に戻す。控えが空なら、空にする。
    func restore(_ items: [[String: Data]])
}

/// 実際のクリップボード（既定は、一般のもの）。
@MainActor public final class SystemPasteboard: PasteboardAccess {
    private let pasteboard: NSPasteboard
    public init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var saved: [String: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { saved[type.rawValue] = data } }
            return saved
        }
    }

    public func writeTransient(text: String) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
    }

    public func restore(_ items: [[String: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

/// 前面のアプリへ、文字を入れる：**クリップボードに書いて、⌘V を送り、少しあとに、元のクリップボードへ戻す**（Hex と同じ方式）。
/// - 戻すのは、**そのあとに、ほかのアプリが、クリップボードを書き換えていないときだけ**（利用者が、続けてコピーしたものを、消さない）。
/// - 文字は、クリップボードの履歴に残さない印をつけて書く。
/// - ⌘V を送るには、アクセシビリティの許可が要る（`vc dictate` のトリガー〔Shift の長押し〕と同じ）。
@MainActor public final class ClipboardPaste {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notTrusted
        public var description: String { "入力するには、アクセシビリティの許可が要ります（システム設定 > プライバシーとセキュリティ > アクセシビリティ）" }
    }

    private let pasteboard: PasteboardAccess
    private let sendPaste: @MainActor () -> Void
    private let restoreDelay: TimeInterval
    private let wait: @MainActor (TimeInterval) async -> Void
    private let trusted: () -> Bool

    public init(pasteboard: PasteboardAccess? = nil,
                sendPaste: @escaping @MainActor () -> Void = ClipboardPaste.sendCommandV,
                restoreDelay: TimeInterval = 0.45,
                wait: @escaping @MainActor (TimeInterval) async -> Void = { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
                trusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.pasteboard = pasteboard ?? SystemPasteboard()
        self.sendPaste = sendPaste
        self.restoreDelay = restoreDelay
        self.wait = wait
        self.trusted = trusted
    }

    /// 前面のアプリへ、文字を入れる。許可がなければ、クリップボードに触らずに、投げる。
    public func insert(_ text: String) async throws {
        guard trusted() else { throw Failure.notTrusted }
        guard !text.isEmpty else { return }
        let original = pasteboard.snapshot()
        pasteboard.writeTransient(text: text)
        let ours = pasteboard.changeCount
        sendPaste()
        await wait(restoreDelay)
        if pasteboard.changeCount == ours { pasteboard.restore(original) }
    }

    /// ⌘V を、前面のアプリへ送る（`V` は、仮想キー 9）。押している修飾キーは、⌘ だけにする（Shift の長押しの直後でも、⌘⇧V にならない）。
    public static func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

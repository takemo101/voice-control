import AppKit
import Foundation

/// クリップボード（ペーストボード）への、小さな口。実装は `SystemPasteboard`。テストでは、偽物に替える。
@MainActor public protocol PasteboardAccess: AnyObject {
    /// 中身が変わるたびに増える数（ほかのアプリが、コピーしたかを知る）。
    var changeCount: Int { get }
    /// 中身を、すべて（型ごとのデータ）、控える。
    func snapshot() -> [[String: Data]]
    /// 文字を書く。**クリップボードの履歴アプリが、記録しない印**（`org.nspasteboard.TransientType`・`ConcealedType`）つき。
    /// 文字は、**貼り付け先が読もうとした時に、渡す**（`textWasRead` で、読まれたかが分かる）。
    func writeTransient(text: String)
    /// `writeTransient` で書いた文字を、貼り付け先が、読んだか（⌘V が、受け付けられた印）。
    var textWasRead: Bool { get }
    /// 文字を、ふつうのクリップボードの中身として書く（印なし。貼り付けられなかったとき、利用者が、手で貼れるように）。
    func writePlain(text: String)
    /// 控えを、元に戻す。控えが空なら、空にする。
    func restore(_ items: [[String: Data]])
}

/// 実際のクリップボード（既定は、一般のもの）。
@MainActor public final class SystemPasteboard: PasteboardAccess {
    /// 文字を、読まれた時に渡す（遅延）。読まれたかを、覚える（貼り付け先が、別のスレッドで、読むこともある）。
    private final class TextProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
        private let text: String
        private let lock = NSLock()
        private var read = false
        init(_ text: String) { self.text = text }
        var wasRead: Bool { lock.withLock { read } }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            lock.withLock { read = true }
            item.setString(text, forType: type)
        }
    }

    private let pasteboard: NSPasteboard
    /// ペーストボードは、提供者を保持しない：次に書くまで、ここで持つ。
    private var provider: TextProvider?
    public init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var saved: [String: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { saved[type.rawValue] = data } }
            return saved
        }
    }

    public var textWasRead: Bool { provider?.wasRead ?? false }

    public func writeTransient(text: String) {
        let provider = TextProvider(text)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        self.provider = provider
        pasteboard.writeObjects([item])
    }

    public func writePlain(text: String) {
        pasteboard.clearContents()
        provider = nil
        pasteboard.setString(text, forType: .string)
    }

    public func restore(_ items: [[String: Data]]) {
        pasteboard.clearContents()
        provider = nil
        guard !items.isEmpty else { return }
        let restored = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

/// 前面のアプリへ、文字を入れる：**クリップボードに書いて、⌘V を送り、貼り付け先が読んだのを確かめて、元のクリップボードへ戻す**（Hex と同じ方式に、確かめを足した）。
/// - **読まれたかを、見る**：文字は、貼り付け先が読もうとした時に渡す。読まれなければ、⌘V が、受け付けられなかった（一度だけ、送り直す）。それでも読まれなければ、**入力できなかったと、返す**（成功に見せない）。文字は、クリップボードに残して、利用者が、手で貼れるようにする。
/// - 戻すのは、**読まれたあとの少しの間（貼り付けが終わるまで）が過ぎて、そのあとに、ほかのアプリが、クリップボードを書き換えていないときだけ**（利用者が、続けてコピーしたものを、消さない）。
/// - 文字は、クリップボードの履歴に残さない印をつけて書く。
/// - ⌘V を送るには、アクセシビリティの許可が要る（`vc dictate` のトリガー〔Shift の長押し〕と同じ）。
@MainActor public final class ClipboardPaste {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notTrusted
        public var description: String { "入力するには、アクセシビリティの許可が要ります（システム設定 > プライバシーとセキュリティ > アクセシビリティ）" }
    }

    public enum Outcome: Equatable {
        case inserted
        /// 貼り付け先が、受け取らなかった。`keptOnClipboard`：文字を、クリップボードに残したか（待つ間に、ほかのアプリが書き換えていたら、残せない）。
        case notReceived(keptOnClipboard: Bool)
    }

    private static let tick: TimeInterval = 0.03

    private let pasteboard: PasteboardAccess
    private let sendPaste: @MainActor () -> Void
    private let firstWait: TimeInterval
    private let retryWait: TimeInterval
    private let settleDelay: TimeInterval
    private let wait: @MainActor (TimeInterval) async -> Void
    private let trusted: () -> Bool

    /// - firstWait：1 回目の ⌘V のあと、読まれるのを待つ上限（秒）。retryWait：送り直したあと。settleDelay：読まれてから、戻すまで（貼り付けが終わるのを待つ。Hex は、0.5 秒）。
    public init(pasteboard: PasteboardAccess? = nil,
                sendPaste: @escaping @MainActor () -> Void = ClipboardPaste.sendCommandV,
                firstWait: TimeInterval = 0.8,
                retryWait: TimeInterval = 1.5,
                settleDelay: TimeInterval = 0.4,
                wait: @escaping @MainActor (TimeInterval) async -> Void = { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
                trusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.pasteboard = pasteboard ?? SystemPasteboard()
        self.sendPaste = sendPaste
        self.firstWait = firstWait
        self.retryWait = retryWait
        self.settleDelay = settleDelay
        self.wait = wait
        self.trusted = trusted
    }

    /// 前面のアプリへ、文字を入れる。許可がなければ、クリップボードに触らずに、投げる。
    @discardableResult
    public func insert(_ text: String) async throws -> Outcome {
        guard trusted() else { throw Failure.notTrusted }
        guard !text.isEmpty else { return .inserted }
        let original = pasteboard.snapshot()
        pasteboard.writeTransient(text: text)
        let ours = pasteboard.changeCount
        var read = false
        for window in [firstWait, retryWait] {
            sendPaste()
            read = await waitForRead(up: window, ours: ours)
            if read || pasteboard.changeCount != ours { break }   // 待つ間に、ほかのアプリが書いたら、送り直さない
        }
        guard read else {
            let intact = pasteboard.changeCount == ours
            if intact { pasteboard.writePlain(text: text) }
            return .notReceived(keptOnClipboard: intact)
        }
        await wait(settleDelay)
        if pasteboard.changeCount == ours { pasteboard.restore(original) }
        return .inserted
    }

    /// 文字が読まれるまで、最長 `window` 秒、待つ。ほかのアプリが、クリップボードを書き換えたら、やめる。
    private func waitForRead(up window: TimeInterval, ours: Int) async -> Bool {
        var waited: TimeInterval = 0
        while waited < window {
            if pasteboard.textWasRead { return true }
            if pasteboard.changeCount != ours { return false }
            await wait(Self.tick)
            waited += Self.tick
        }
        return pasteboard.textWasRead
    }

    /// ⌘V を、前面のアプリへ送る：⌘ の押下・`V` の押下と離し・⌘ の解放を、15 ミリ秒ずつあけて、順に送る（修飾キーの状態を、自分のイベントから追うアプリ〔リモートデスクトップ・仮想マシン〕でも、読み取れる）。
    /// `V` は、いまの配列で `v` を出すキー（引けなければ、仮想キー 9）。押している修飾キーは、⌘ だけにする（Shift の長押しの直後でも、⌘⇧V にならない）。
    public static func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let v = KeyboardLayout.keyCode(for: "v") ?? 9
        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, modifierChange: Bool = false) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            if modifierChange { event?.type = .flagsChanged }
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        let commandKey: CGKeyCode = 55
        post(commandKey, down: true, flags: .maskCommand, modifierChange: true)
        usleep(15_000)
        post(v, down: true, flags: .maskCommand)
        usleep(15_000)
        post(v, down: false, flags: .maskCommand)
        usleep(15_000)
        post(commandKey, down: false, flags: [], modifierChange: true)
    }
}

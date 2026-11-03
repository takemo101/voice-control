import Foundation
import VCPCControl

/// 操作を記録する `Desktop`（画面は、スクロール領域が 1 つ。`failure` があれば、`perform` が失敗する）。
public final class RecordingDesktop: Desktop, @unchecked Sendable {
    public static let area = UIElement(ref: "@s:e1", role: "scrollarea", name: "notes", actions: ["Scroll"])
    private let lock = NSLock()
    private var items: [Step] = []
    private var error: Error?

    public init() {}

    public var failure: Error? {
        get { lock.lock(); defer { lock.unlock() }; return error }
        set { lock.lock(); error = newValue; lock.unlock() }
    }

    public var performed: [Step] { lock.lock(); defer { lock.unlock() }; return items }
    public func snapshot() throws -> Snapshot { Snapshot(app: "", elements: [Self.area]) }
    public func apps() throws -> [String] { [] }
    public func perform(_ step: Step) throws {
        if let failure { throw failure }
        lock.lock(); items.append(step); lock.unlock()
    }
}

/// 決まった前面のアプリ・開けるアプリを返し、操作は何もしない `Desktop`（画面に、操作できる要素はない）。`snapshotError` があれば、画面を読むのに失敗する。
public struct StaticDesktop: Desktop {
    public var app: String
    public var installedApps: [String]
    public var snapshotError: Error?

    public init(app: String = "", installedApps: [String] = [], snapshotError: Error? = nil) {
        self.app = app
        self.installedApps = installedApps
        self.snapshotError = snapshotError
    }

    public func snapshot() throws -> Snapshot {
        if let snapshotError { throw snapshotError }
        return Snapshot(app: app, elements: [])
    }
    public func apps() throws -> [String] { installedApps }
    public func perform(_ step: Step) throws {}
}

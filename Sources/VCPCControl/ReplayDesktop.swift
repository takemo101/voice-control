import Foundation

/// 固定した画面（snapshot の JSON）とアプリの一覧を返す `Desktop`。**操作は、しない**（`perform` は何も起こさない）。
/// 実機を使わずに、選択の当たり率を測る（`vc eval`）。
public struct ReplayDesktop: Desktop {
    private let snap: Snapshot
    private let appNames: [String]
    public init(snapshot: Snapshot, apps: [String]) { snap = snapshot; appNames = apps }
    public func snapshot() throws -> Snapshot { snap }
    public func apps() throws -> [String] { appNames }
    public func perform(_ step: Step) throws {}
}

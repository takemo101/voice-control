import Foundation
import VCCore
import VCSkill

/// アダプターの、いまの状態（**ファイルと `PATH` を見るだけ**：画面・コマンドが、同じ見方をする）。
enum AdapterStatus: Equatable {
    /// 利用者が自分で入れたものを、使っている（`PATH`・よくある置き場所・`nvm`）。
    case own(path: String)
    /// アプリが入れたもの。`current`：固定した版か。
    case managed(version: String, current: Bool)
    case notInstalled(hasNode: Bool)

    static func of(_ adapter: ACPAdapter, directories: [String] = AgentLocator.searchDirectories(), root: URL = ACPAdapterStore.root) -> AdapterStatus {
        if let own = directories.map({ "\($0)/\(adapter.executable)" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return .own(path: own) }
        if let version = ACPAdapterStore.installedVersion(of: adapter, root: root) { return .managed(version: version, current: version == adapter.version) }
        return .notInstalled(hasNode: ACPAdapterInstaller.npmPath(directories: directories) != nil)
    }

    /// 画面・コマンドに出す 1 行。
    func summary(for adapter: ACPAdapter) -> String {
        switch self {
        case let .own(path): return tr("自分で入れたものを使っています（\(path)）")
        case let .managed(version, current): return current ? tr("導入済み（\(version)）") : tr("導入済み（\(version)）。固定した版は \(adapter.version) です")
        case let .notInstalled(hasNode): return hasNode ? tr("未導入。入れるまでは、従来の方式で話します") : tr("未導入（Node.js が見つかりません）。従来の方式で話します")
        }
    }

    /// アダプターが使えるか（自分で入れたもの・アプリが入れたもの）。
    var isUsable: Bool { if case .notInstalled = self { return false }; return true }

    /// 入れる・更新する操作が要るか（自分で入れたものを使っているときは、要らない）。
    var canInstall: Bool {
        switch self {
        case .own: return false
        case let .managed(_, current): return !current
        case let .notInstalled(hasNode): return hasNode
        }
    }
}

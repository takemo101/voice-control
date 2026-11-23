import Foundation

/// スキルを実行するモデルのサーバー（OpenAI 互換：oMLX・Strata など）の、**APIキー**の保管庫（`~/.voice-control/engine-keys.json`）。サーバー（`ホスト:ポート`）ごとに 1 つ。
/// - **自分だけが読める**（0600。置き場所のフォルダは 0700）。設定ファイル（`settings.json`）には、置かない（誰でも読める権限で、サポートの依頼などに、貼られやすい）。
/// - **書くだけ**：画面は、設定済みかどうかだけ見せる。ログ・画面・引数・環境変数へ、出さない。
/// - 鍵は、そのサーバーへの `Authorization: Bearer` にだけ使う（リダイレクトは、追わない）。
public struct EngineKeyStore: Sendable {
    public let file: URL

    public init(file: URL = VoiceControlHome.root.appendingPathComponent("engine-keys.json")) { self.file = file }

    public static var standard: EngineKeyStore { EngineKeyStore() }

    public enum StoreError: Error, CustomStringConvertible {
        case cannotWrite
        public var description: String { tr("APIキーを保存できません") }
    }

    /// サーバー（`ホスト:ポート`）のキー。なければ nil。読めないファイルは、なしとして扱う（鍵が要るサーバーは、401 で、利用者に伝わる）。
    public func key(for endpoint: String) -> String? {
        let value = load()[endpoint.lowercased()]
        return value?.isEmpty == false ? value : nil
    }

    public func hasKey(for endpoint: String) -> Bool { key(for: endpoint) != nil }

    /// 保存する（空の文字は、消す）。前後の空白・改行は、落とす（貼り付けで、混ざりやすい）。
    public func set(_ key: String, for endpoint: String) throws {
        var all = load()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { all.removeValue(forKey: endpoint.lowercased()) } else { all[endpoint.lowercased()] = trimmed }
        try save(all)
    }

    public func remove(for endpoint: String) throws { try set("", for: endpoint) }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file), let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }   // try?: ファイルがなければ、鍵は、なし
        return table
    }

    private func save(_ table: [String: String]) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(table)
        // 権限を決めてから、置き換える（途中で、ほかの人に読める時間を、作らない）
        let temporary = directory.appendingPathComponent(".engine-keys-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw StoreError.cannotWrite }
        if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) } else { try FileManager.default.moveItem(at: temporary, to: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

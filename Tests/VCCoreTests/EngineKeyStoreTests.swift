import Foundation
import Testing
@testable import VCCore

/// モデルのサーバーの APIキーの保管庫：自分だけが読める・サーバー別・書くだけ。**キーは、作り物**。
@Suite struct EngineKeyStoreTests {
    private func store() -> (EngineKeyStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vc-keys-\(UUID().uuidString)")
        return (EngineKeyStore(file: directory.appendingPathComponent("engine-keys.json")), directory)
    }

    @Test func aKeyIsKeptPerServerAndOnlyTheOwnerCanReadTheFile() throws {
        let (keys, directory) = store(); defer { try? FileManager.default.removeItem(at: directory) }
        try keys.set("  k-sample-1\n", for: "192.168.1.5:8080")                        // 貼り付けの空白・改行は、落とす
        try keys.set("k-sample-2", for: "127.0.0.1:8000")
        #expect(keys.key(for: "192.168.1.5:8080") == "k-sample-1" && keys.key(for: "127.0.0.1:8000") == "k-sample-2")
        #expect(keys.key(for: "192.168.1.5:9999") == nil && !keys.hasKey(for: "10.0.0.1:8080"))   // 別のサーバーには、使わない
        #expect(keys.key(for: "BOX.local:8000") == nil)
        try keys.set("k-sample-3", for: "Box.local:8000")
        #expect(keys.key(for: "box.local:8000") == "k-sample-3")                     // 大文字小文字は、区別しない
        let file = (try FileManager.default.attributesOfItem(atPath: keys.file.path)[.posixPermissions] as? NSNumber)?.intValue
        let folder = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(file == 0o600 && folder == 0o700)
    }

    @Test func savingAnEmptyKeyRemovesItAndAnUnreadableFileMeansNoKey() throws {
        let (keys, directory) = store(); defer { try? FileManager.default.removeItem(at: directory) }
        try keys.set("k-sample", for: "10.0.0.1:1")
        try keys.remove(for: "10.0.0.1:1")
        #expect(!keys.hasKey(for: "10.0.0.1:1"))
        try "壊れた".write(to: keys.file, atomically: true, encoding: .utf8)
        #expect(keys.key(for: "10.0.0.1:1") == nil)                                   // 読めなければ、キーなし（401 で、利用者に伝わる）
        try keys.set("k-sample", for: "10.0.0.1:1")                                   // 書き直せる
        #expect(keys.hasKey(for: "10.0.0.1:1"))
    }
}

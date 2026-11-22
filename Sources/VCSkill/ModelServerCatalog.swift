import Foundation
import VCCore

/// モデルのサーバー（Ollama・OpenAI 互換）が、**いま持っているモデルの一覧**を取る（設定ウィンドウ > モデル の「一覧」）。**質問は送らない**（一覧の取得だけ：話した内容・画面の内容は、出ない）。
/// 場所・APIキーは、エンジンと同じ（`ServerAddress`・`EngineKeyStore`）。
public enum ModelServerCatalog {
    public enum Kind: Sendable { case ollama, openAI }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func list(kind: Kind, server address: ServerAddress, keys: EngineKeyStore = .standard) async throws -> [String] {
        let server = LocalServer(name: kind == .ollama ? "Ollama" : tr("OpenAI 互換サーバー"), address: address, apiKey: keys.key(for: address.endpoint))
        do {
            let (data, status) = try await server.send(path: kind == .ollama ? address.basePath + "/api/tags" : address.root(default: "/v1") + "/models", body: nil)
            guard status == 200 else { throw ChatError.http(status, String(decoding: data, as: UTF8.self)) }
            let names = parse(kind: kind, data: data)
            guard !names.isEmpty else { throw ChatError.badResponse(tr("モデルの一覧が、空です")) }
            return names
        } catch { throw Failure(description: "\(error)") }
    }

    /// 応答から、モデルの名前の一覧（**純粋**）。Ollama：`models[].name`。OpenAI 互換：`data[].id`。読めなければ、空。名前順。
    /// サーバーが返した文字は、非信頼：エンジンの書き方（`Engine.parse`）で通る名前だけ残す（画面に出す前に、使えない名前を、落とす）。
    static func parse(kind: Kind, data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }   // try?: 読めなければ、空（呼ぶ側が、失敗として伝える）
        let raw: [String]
        switch kind {
        case .ollama: raw = (root["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        case .openAI: raw = (root["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        let usable = raw.filter { (try? Engine.parse("ollama:" + $0)) != nil }   // try?: 使えない名前は、残さない
        return Array(Set(usable)).sorted()
    }
}

import Foundation
import VCCore

/// モデルのサーバーの**種類**（通信の決まり）。Ollama と OpenAI 互換で違う部分を、**ここ 1 か所**に集める：`--engine` の接頭辞・表示名・既定の場所・API の経路・モデルの一覧の読み方・サーバーの組み立て（APIキーつき）。
/// 会話（`OllamaChat`・`OpenAICompatibleChat`）・一覧（`ModelServerCatalog`）・画像（`VisionModel`）が、経路や鍵の取り出しを、それぞれ書かない。
public enum ModelServerKind: String, CaseIterable, Sendable {
    case ollama
    case openAI = "openai"

    /// `--engine` の接頭辞（`ollama:`・`openai:`）。
    var prefix: String { rawValue + ":" }

    /// 表示名（エラーの文・確認）。
    var name: String { self == .ollama ? "Ollama" : tr("OpenAI 互換サーバー") }

    /// 場所を省いたときの場所。OpenAI 互換は、既定のポートがない（nil：場所が要る）。
    public var defaultAddress: ServerAddress? { self == .ollama ? .loopback(port: 11434) : nil }

    /// 質問を送る経路。Ollama：`<経路>/api/chat`。OpenAI 互換：`<経路>/chat/completions`（経路を省くと `/v1`）。
    func chatPath(_ address: ServerAddress) -> String {
        self == .ollama ? address.basePath + "/api/chat" : address.root(default: "/v1") + "/chat/completions"
    }

    /// モデルの一覧の経路。Ollama：`<経路>/api/tags`。OpenAI 互換：`<経路>/models`。
    func listPath(_ address: ServerAddress) -> String {
        self == .ollama ? address.basePath + "/api/tags" : address.root(default: "/v1") + "/models"
    }

    /// そのサーバーへの通信（場所・APIキー：サーバー別の保管庫）。
    func server(at address: ServerAddress, keys: EngineKeyStore = .standard) -> LocalServer {
        LocalServer(name: name, address: address, apiKey: keys.key(for: address.endpoint))
    }

    /// 一覧の応答から、モデルの名前（**純粋**）。Ollama：`models[].name`。OpenAI 互換：`data[].id`。読めなければ、nil（空の一覧は、空）。
    func modelNames(in data: Data) -> [String]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }   // try?: 読めなければ nil（呼ぶ側が、失敗として伝える）
        switch self {
        case .ollama: return (root["models"] as? [[String: Any]]).map { $0.compactMap { $0["name"] as? String } }
        case .openAI: return (root["data"] as? [[String: Any]]).map { $0.compactMap { $0["id"] as? String } }
        }
    }

    /// サーバーが持っているモデルの名前（サーバーが返したまま）。質問は送らない。失敗は `ChatError`。
    func listModelNames(on server: LocalServer) async throws -> [String] {
        let (data, status) = try await server.send(path: listPath(server.address), body: nil, timeout: 15)
        guard status == 200 else { throw ChatError.http(status, String(decoding: data, as: UTF8.self)) }
        guard let names = modelNames(in: data) else { throw ChatError.badResponse(tr("モデルの一覧を読めません")) }
        return names
    }
}

import Foundation
import VCCore

/// この Mac（`127.0.0.1:<ポート>`）か、**同じ LAN** の HTTP サーバー（`ServerAddress`：ホストは、私的なアドレスと `.local` の名前だけ。インターネットへは、向けられない）。
struct LocalServer: Sendable, Equatable {
    /// 表示用の名前（`Ollama` など）。
    let name: String
    let address: ServerAddress
    /// APIキー（`Authorization: Bearer`）。なければ、付けない。**サーバー別の保管庫**（`EngineKeyStore`）から、呼び出し側が渡す。
    let apiKey: String?

    init(name: String, address: ServerAddress, apiKey: String? = nil) { self.name = name; self.address = address; self.apiKey = apiKey?.isEmpty == true ? nil : apiKey }

    var endpoint: String { address.endpoint }

    /// JSON を送る（`body` があれば POST、なければ GET）。状態コードと本文を返す。接続できなければ `ChatError.notRunning`・時間内に終わらなければ `timedOut`。
    /// **リダイレクトは、追わない**（APIキーを、別のところへ、送らない）。`timeout`：応答が終わるまでの上限（質問は、初回に、モデルの読み込みで長い。一覧・確認は、短く）。
    /// 通信は `LocalHTTP`（`URLSession` ではない：HTTP を、App Transport Security が、断るため）。
    func send(path: String, body: [String: Any]?, timeout: TimeInterval = 180, lookup: @Sendable (String) async -> [String] = ServerAddress.systemLookup) async throws -> (data: Data, status: Int) {
        let host = try await address.connectHost(lookup: lookup)   // `.local` の名前は、ここで引いて、私的なアドレスか確かめる（引いた IP へ、つなぐ）
        var headers: [(String, String)] = []
        if let apiKey { headers.append(("Authorization", "Bearer \(apiKey)")) }
        var payload: Data?
        if let body {
            headers.append(("Content-Type", "application/json"))
            payload = try JSONSerialization.data(withJSONObject: body)
        }
        let request = LocalHTTP.requestData(method: body == nil ? "GET" : "POST", host: host, port: address.port, path: path, headers: headers, body: payload)
        do {
            let response = try await LocalHTTP.send(request, to: host, port: address.port, timeout: timeout)
            if response.status == 401 || response.status == 403 { throw ChatError.unauthorized(server: name, endpoint: endpoint) }
            return (response.body, response.status)
        } catch LocalHTTP.Failure.unreachable {
            throw ChatError.notRunning(server: name, endpoint: endpoint)
        } catch LocalHTTP.Failure.timedOut {
            throw ChatError.timedOut(server: name, endpoint: endpoint)
        } catch let LocalHTTP.Failure.malformed(why) {
            throw ChatError.badResponse(why)
        }
    }
}

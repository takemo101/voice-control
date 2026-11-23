import Foundation
import Testing
@testable import VCSkill
import VCCore

/// スキルを実行するモデルのサーバーの場所：この Mac・LAN だけ。`.local` の名前は、通信の直前に引いて、私的なアドレスか確かめる。APIキーは、そのサーバーにだけ、付く。**キー・文は、作り物**。
@Suite struct ServerAddressTests {
    @Test func privateRangesAreAcceptedAndEverythingElseIsRefused() {
        for ok in ["10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.255", "192.168.0.10", "169.254.1.1", "100.64.0.1", "100.127.255.255", "127.0.0.1", "MY-Mac.local", "a.local"] {
            #expect((try? ServerAddress.make(host: ok, port: 1)) != nil, "\(ok)")
        }
        for bad in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.167.0.1", "100.63.0.1", "100.128.0.1", "11.0.0.1", "example.com", "evil.local.example.com", ".local", "a b.local", "0.0.0.0", "256.1.1.1", "1.2.3", "::1", "fe80::1", "192.168.1.1.", "-x.local"] {
            #expect((try? ServerAddress.make(host: bad, port: 1)) == nil, "\(bad)")
        }
    }

    @Test func aBasePathMustBeASafeSlashSeparatedPathAndIsNotPartOfTheKeyOrTheApproval() throws {
        for ok in ["/v1", "/v2", "/openai/v1", "/api/v1", "/a_b.c~d-e"] { #expect(ServerAddress.validBasePath(ok), "\(ok)") }
        for bad in ["", "v1", "/", "//v1", "/v1/", "/../x", "/a/../b", "/./a", "/v1?x=1", "/v1#f", "/a b", "/あ", String(repeating: "/a", count: 60)] { #expect(!ServerAddress.validBasePath(bad), "\(bad)") }
        #expect(throws: ServerAddress.Problem.invalidPath("/../x")) { try ServerAddress.make(host: "10.0.0.1", port: 1, basePath: "/../x") }
        let one = try ServerAddress.make(host: "10.0.0.1", port: 8080, basePath: "/v1"), two = try ServerAddress.make(host: "10.0.0.1", port: 8080, basePath: "/v2")
        #expect(one.endpoint == "10.0.0.1:8080" && two.endpoint == one.endpoint && one != two)     // 許可・キーは、サーバー（ホスト:ポート）ごと
        #expect(one.root(default: "/v1") == "/v1" && ServerAddress.loopback(port: 1).root(default: "/v1") == "/v1" && two.root(default: "/v1") == "/v2")
    }

    @Test func aLocalNameMustResolveOnlyToPrivateAddressesBeforeAnythingIsSent() async throws {
        let name = try ServerAddress.make(host: "box.local", port: 8000)
        #expect(try await name.connectHost(lookup: { _ in ["192.168.1.9"] }) == "192.168.1.9")
        await #expect(throws: ChatError.notPrivate(host: "box.local", answer: "93.184.216.34")) { try await name.connectHost(lookup: { _ in ["192.168.1.9", "93.184.216.34"] }) }   // 1 つでも、外なら、送らない
        await #expect(throws: ChatError.unresolved(host: "box.local")) { try await name.connectHost(lookup: { _ in [] }) }
        let literal = try ServerAddress.make(host: "10.0.0.2", port: 1)
        #expect(try await literal.connectHost(lookup: { _ in ["93.184.216.34"] }) == "10.0.0.2")          // アドレスで書かれていれば、引かない
    }
}

/// 小さな偽のサーバー（Python）：受けたヘッダーを記録し、`/v1/models` に答える。`/secure` は、キーがないと 401。`/redir` は、別のポートへ 302。
private enum FakeServer {
    static let script = #"""
    import sys, json, http.server, socketserver
    log = open(sys.argv[1], "a")
    other = sys.argv[2]
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            log.write("%s auth=%s\n" % (self.path, self.headers.get("Authorization"))); log.flush()
            if self.path == "/chunked":
                self.protocol_version = "HTTP/1.1"
                self.send_response(200); self.send_header("Transfer-Encoding", "chunked"); self.send_header("Connection", "close"); self.end_headers()
                for part in (b'{"data": [{"id"', b': "chunked-model"}]}'): self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
                self.wfile.write(b"0\r\n\r\n"); return
            if self.path == "/slow":
                import time; time.sleep(3)
            if self.path == "/big":
                body = b"x" * 3_000_000
                self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
            if self.path.endswith("/api/tags"):
                body = json.dumps({"models": [{"name": "b:latest"}, {"name": "a:7b"}, {"name": "bad name"}, {"name": "gpt-oss:120b-cloud"}]}).encode()
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body); return
            if self.path == "/redir":
                self.send_response(302); self.send_header("Location", "http://127.0.0.1:%s/leak" % other); self.end_headers(); return
            if self.path == "/secure" and self.headers.get("Authorization") != "Bearer k-sample":
                self.send_response(401); self.end_headers(); self.wfile.write(b"no"); return
            body = json.dumps({"data": [{"id": "m"}]}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    with socketserver.TCPServer(("127.0.0.1", 0), H) as s:
        print(s.server_address[1], flush=True)
        s.serve_forever()
    """#
}

@Suite struct LocalServerKeyTests {
    private func start(other: Int = 1) throws -> (process: Process, port: Int, log: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vc-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("s.py"), log = directory.appendingPathComponent("log.txt")
        try FakeServer.script.write(to: script, atomically: true, encoding: .utf8)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["python3", script.path, log.path, String(other)]
        process.standardOutput = pipe
        try process.run()
        // ポートが書かれた 1 行を、読めるまで待つ（起動の途中で、読み終えない）
        var text = ""
        let limit = Date().addingTimeInterval(10)
        while !text.contains("\n"), Date() < limit {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.02) } else { text += String(decoding: chunk, as: UTF8.self) }
        }
        return (process, Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, log, directory)
    }

    @Test func theKeyIsSentAsABearerTokenAndAMissingOrWrongKeyIsReportedAsUnauthorized() async throws {
        let server = try start(); defer { server.process.terminate(); try? FileManager.default.removeItem(at: server.directory) }
        let address = ServerAddress.loopback(port: server.port)
        let withKey = LocalServer(name: "t", address: address, apiKey: "k-sample")
        let ok = try await withKey.send(path: "/secure", body: nil)
        #expect(ok.status == 200)
        await #expect(throws: ChatError.unauthorized(server: "t", endpoint: address.endpoint)) { try await LocalServer(name: "t", address: address, apiKey: nil).send(path: "/secure", body: nil) }
        await #expect(throws: ChatError.unauthorized(server: "t", endpoint: address.endpoint)) { try await LocalServer(name: "t", address: address, apiKey: "wrong").send(path: "/secure", body: nil) }
        let log = (try? String(contentsOf: server.log, encoding: .utf8)) ?? ""
        #expect(log.contains("/secure auth=Bearer k-sample") && log.contains("/secure auth=None"))
        // キーが無いときは、ヘッダーを付けない（空の文字も、なしと同じ）
        _ = try await LocalServer(name: "t", address: address, apiKey: "").send(path: "/v1/models", body: nil)
        #expect(((try? String(contentsOf: server.log, encoding: .utf8)) ?? "").contains("/v1/models auth=None"))
    }

    @Test func theModelListOfEitherServerKindIsReadAndUnusableNamesAreDropped() async throws {
        let server = try start(); defer { server.process.terminate(); try? FileManager.default.removeItem(at: server.directory) }
        let keys = EngineKeyStore(file: server.directory.appendingPathComponent("keys.json"))
        let address = ServerAddress.loopback(port: server.port)
        #expect(try await ModelServerCatalog.list(kind: .openAI, server: address, keys: keys) == ["m"])                   // `data[].id`
        #expect(try await ModelServerCatalog.list(kind: .ollama, server: address, keys: keys) == ["a:7b", "b:latest"])     // `models[].name`：使えない名前（空白・クラウド）は、残さない
        let missing = ServerAddress.loopback(port: 1)                                                                      // つながらない：理由が、文で返る
        await #expect(throws: ModelServerCatalog.Failure.self) { try await ModelServerCatalog.list(kind: .openAI, server: missing, keys: keys) }
        #expect(ModelServerCatalog.parse(kind: .openAI, data: Data("壊れた".utf8)).isEmpty)
    }

    /// 経路：OpenAI 互換は、`<経路>/models`（省くと `/v1`）。Ollama は、`<経路>/api/tags`（省くと、なし）。
    @Test func theBasePathDecidesWhereTheApiIsAskedForTheListOfModels() async throws {
        let server = try start(); defer { server.process.terminate(); try? FileManager.default.removeItem(at: server.directory) }
        let keys = EngineKeyStore(file: server.directory.appendingPathComponent("keys.json"))
        _ = try await ModelServerCatalog.list(kind: .openAI, server: .loopback(port: server.port), keys: keys)
        _ = try await ModelServerCatalog.list(kind: .openAI, server: .loopback(port: server.port, basePath: "/v2"), keys: keys)
        _ = try await ModelServerCatalog.list(kind: .openAI, server: .loopback(port: server.port, basePath: "/openai/v1"), keys: keys)
        _ = try await ModelServerCatalog.list(kind: .ollama, server: .loopback(port: server.port), keys: keys)
        _ = try await ModelServerCatalog.list(kind: .ollama, server: .loopback(port: server.port, basePath: "/ollama"), keys: keys)
        let log = (try? String(contentsOf: server.log, encoding: .utf8)) ?? ""
        for expected in ["/v1/models ", "/v2/models ", "/openai/v1/models ", "/api/tags ", "/ollama/api/tags "] { #expect(log.contains(expected), "\(expected)") }
    }

    /// 通信は `LocalHTTP`（`URLSession` ではない）：チャンクの応答・大きな応答・時間切れ・取りやめ。
    @Test func theTransportReadsChunkedAndLargeResponsesAndStopsOnTimeoutAndCancellation() async throws {
        let server = try start(); defer { server.process.terminate(); try? FileManager.default.removeItem(at: server.directory) }
        let local = LocalServer(name: "t", address: .loopback(port: server.port), apiKey: nil)
        let chunked = try await local.send(path: "/chunked", body: nil)
        #expect(chunked.status == 200 && String(decoding: chunked.data, as: UTF8.self) == #"{"data": [{"id": "chunked-model"}]}"#)
        let big = try await local.send(path: "/big", body: nil)
        #expect(big.status == 200 && big.data.count == 3_000_000)
        let started = Date()
        await #expect(throws: ChatError.timedOut(server: "t", endpoint: local.endpoint)) { try await local.send(path: "/slow", body: nil, timeout: 0.5) }
        #expect(Date().timeIntervalSince(started) < 2.5)                                           // 待たずに、時間切れ
        let task = Task { try await local.send(path: "/slow", body: nil, timeout: 30) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let cancelStart = Date()
        _ = await task.result
        #expect(Date().timeIntervalSince(cancelStart) < 2.0)                                        // 取りやめで、すぐ止まる
    }

    @Test func aRedirectIsNotFollowedSoTheKeyCannotLeakToAnotherServer() async throws {
        let target = try start(); defer { target.process.terminate(); try? FileManager.default.removeItem(at: target.directory) }
        let server = try start(other: target.port); defer { server.process.terminate(); try? FileManager.default.removeItem(at: server.directory) }
        let reply = try await LocalServer(name: "t", address: .loopback(port: server.port), apiKey: "k-sample").send(path: "/redir", body: nil)
        #expect(reply.status == 302)                                                                   // 追わずに、そのまま返る
        #expect(!((try? String(contentsOf: target.log, encoding: .utf8)) ?? "").contains("/leak"))      // 転送先には、何も届かない
    }
}

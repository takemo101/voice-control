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

    @Test func aRedirectIsNotFollowedSoTheKeyCannotLeakToAnotherServer() async throws {
        let target = try start(); defer { target.process.terminate(); try? FileManager.default.removeItem(at: target.directory) }
        let server = try start(other: target.port); defer { server.process.terminate(); try? FileManager.default.removeItem(at: server.directory) }
        let reply = try await LocalServer(name: "t", address: .loopback(port: server.port), apiKey: "k-sample").send(path: "/redir", body: nil)
        #expect(reply.status == 302)                                                                   // 追わずに、そのまま返る
        #expect(!((try? String(contentsOf: target.log, encoding: .utf8)) ?? "").contains("/leak"))      // 転送先には、何も届かない
    }
}

import Foundation
import Network

/// この Mac・同じ LAN のモデルのサーバーへの、**HTTP/1.1 の小さな通信**（Network.framework）。**`URLSession` を使わない理由**：`URLSession` は、アプリの通信の安全の方針（App Transport Security）で、**暗号化されない HTTP を、断る**（`Code=-1022`）。免除されるのは、この Mac と、一部の LAN の住所だけで、**Tailscale の `100.64〜127.x` などは、断られた**（実測）。
/// 通信先は、呼ぶ側（`LocalServer`）が、すでに、この Mac・LAN の私的なアドレスだと確かめている（`ServerAddress`）。**ここは、IP アドレスへ、直接つなぐ**（名前を、引き直さない）。リダイレクトは、追わない。
/// 要求は `Connection: close`：応答の終わりは、`Content-Length`・チャンク・接続の終了のどれか。
enum LocalHTTP {
    struct Response: Equatable {
        let status: Int
        let body: Data
    }

    enum Failure: Error, Equatable {
        /// つながらない（拒まれた・届かない・切れた）。
        case unreachable
        /// 時間内に、応答が終わらない。
        case timedOut
        /// 応答を、読めない。
        case malformed(String)
    }

    /// 応答の大きさの上限（これを超える応答は、読まない）。
    static let maxResponseBytes = 32_000_000

    // MARK: 要求

    /// 要求の文（**純粋**）。`headers` の値に、改行は入れない（入っていたら、呼ぶ側の誤り：落とす）。
    static func requestData(method: String, host: String, port: Int, path: String, headers: [(String, String)], body: Data?) -> Data {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host):\(port)", "Connection: close", "Accept: application/json"]
        for (name, value) in headers { lines.append("\(name): \(value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))") }
        if let body { lines.append("Content-Length: \(body.count)") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { data.append(body) }
        return data
    }

    // MARK: 応答の読み取り（純粋）

    /// ここまでに届いた分から、応答を読む。**まだ、終わっていなければ、nil**。`atEOF`：接続が、閉じた（終わりが、ない形の応答は、ここで終わる）。
    static func parse(_ data: Data, atEOF: Bool) throws -> Response? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            if atEOF { throw Failure.malformed("ヘッダーが終わらない") }
            return nil
        }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let first = head.first, first.hasPrefix("HTTP/"), let status = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw Failure.malformed("状態の行") }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = Data(data[headerEnd.upperBound...])
        if (100..<200).contains(status) || status == 204 || status == 304 { return Response(status: status, body: Data()) }   // 本文のない応答
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return try decodeChunked(rest, atEOF: atEOF).map { Response(status: status, body: $0) }
        }
        if let length = headers["content-length"].flatMap({ Int($0) }) {
            guard length >= 0, length <= maxResponseBytes else { throw Failure.malformed("大きすぎる応答") }
            if rest.count >= length { return Response(status: status, body: rest.prefix(length)) }
            if atEOF { throw Failure.malformed("本文が、途中で切れた") }
            return nil
        }
        return atEOF ? Response(status: status, body: rest) : nil   // 終わりの印がない：接続が閉じたとき
    }

    /// チャンクの本文を、つなぐ。最後のチャンク（大きさ 0）まで届いていなければ、nil（`atEOF` なら、途中で切れた失敗）。
    static func decodeChunked(_ data: Data, atEOF: Bool) throws -> Data? {
        var out = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { break }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw Failure.malformed("チャンクの大きさ") }
            if size == 0 { return out }   // 最後のチャンク（あとの、追加のヘッダーは、読まない）
            let start = lineEnd.upperBound
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { break }   // 本文と、そのあとの CRLF が、揃っていない
            out.append(data[start..<data.index(start, offsetBy: size)])
            guard out.count <= maxResponseBytes else { throw Failure.malformed("大きすぎる応答") }
            index = data.index(start, offsetBy: size + 2)
        }
        if atEOF { throw Failure.malformed("チャンクが、途中で切れた") }
        return nil
    }

    // MARK: 通信

    /// 送って、応答が終わるまで待つ。`timeout`：全体の上限（秒）。取りやめ（`Task` のキャンセル）で、すぐ止まる。
    static func send(_ request: Data, to host: String, port: Int, timeout: TimeInterval) async throws -> Response {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), let address = IPv4Address(host) else { throw Failure.unreachable }
        let exchange = Exchange(connection: NWConnection(host: .ipv4(address), port: nwPort, using: .tcp), request: request, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in exchange.start(continuation) }
        } onCancel: { exchange.cancel() }
    }

    /// 1 回のやり取り。`@unchecked Sendable`：可変の持ち物は、すべて、`lock` の下（通知は、1 本の待ち行列から来る）。
    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let request: Data
        private let timeout: TimeInterval
        private let queue = DispatchQueue(label: "voice-control.local-http")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Response, Error>?
        private var finished = false
        private var received = Data()

        init(connection: NWConnection, request: Data, timeout: TimeInterval) { self.connection = connection; self.request = request; self.timeout = timeout }

        func start(_ continuation: CheckedContinuation<Response, Error>) {
            lock.withLock { self.continuation = continuation }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.sendRequest()
                case .failed, .waiting: self.finish(.failure(Failure.unreachable))   // `waiting`：拒まれた・届かない（待ち直しは、しない）
                case .cancelled: self.finish(.failure(CancellationError()))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(Failure.timedOut)) }
            connection.start(queue: queue)
        }

        func cancel() { finish(.failure(CancellationError())) }

        private func sendRequest() {
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish(.failure(Failure.unreachable)); return }
                self?.receive()
            })
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty { self.lock.withLock { self.received.append(data) } }
                let snapshot = self.lock.withLock { self.received }
                if snapshot.count > LocalHTTP.maxResponseBytes + 65_536 { self.finish(.failure(Failure.malformed("大きすぎる応答"))); return }
                do {
                    if let response = try LocalHTTP.parse(snapshot, atEOF: isComplete || error != nil) { self.finish(.success(response)); return }
                } catch { self.finish(.failure(error)); return }
                if error != nil || isComplete { self.finish(.failure(Failure.unreachable)); return }
                self.receive()
            }
        }

        private func finish(_ result: Result<Response, Error>) {
            let pending: CheckedContinuation<Response, Error>? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                let taken = continuation; continuation = nil
                return taken
            }
            guard let pending else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            pending.resume(with: result)
        }
    }
}

import Darwin
import Foundation
import VCCore

/// スキルを実行するモデルの、サーバーの場所（ホストとポート）。**通信先は、この Mac と、同じ LAN の中だけ**（音声・画面の内容が、インターネットへ出ない）。
/// ホストに書けるもの：
/// - この Mac：`127.0.0.1`・`localhost`（省略すると、これ）。
/// - **LAN**：IPv4 の私的なアドレス（`10.x`・`172.16〜31.x`・`192.168.x`・リンクローカル `169.254.x`・Tailscale などの `100.64〜127.x`）と、`<名前>.local`（mDNS）。
/// **経路（`basePath`）**：API の根（`/v1`・`/v2`・`/openai/v1`・リバースプロキシの下の `/ollama` など）。OpenAI 互換は、省くと `/v1`。Ollama は、省くと、なし（`/api/chat` の前に、足す）。**プロトコルは、HTTP だけ**（HTTPS は、未対応：証明書の扱いが決まっていない）。
/// 公開のホスト名・公開の IP・IPv6 は、書けない。**`.local` の名前は、通信の直前に引いて、すべての答えが私的なアドレスか確かめる**（名前の引き先が、外を指していたら、送らない）。
/// LAN への通信は、暗号化されない（HTTP）。設定では、利用者が、その場所ごとに許可する（`Settings.engineApproved`）。
public struct ServerAddress: Sendable, Equatable {
    public let host: String
    public let port: Int
    /// API の根（`/v1` など）。なければ、空（既定を使う）。**鍵・許可の鍵（`endpoint`）には、含めない**：同じサーバーの、経路違いは、同じ許可・同じキー。
    public let basePath: String

    public static let loopbackHost = "127.0.0.1"

    init(host: String, port: Int, basePath: String = "") { self.host = host; self.port = port; self.basePath = basePath }

    public static func loopback(port: Int, basePath: String = "") -> ServerAddress { ServerAddress(host: loopbackHost, port: port, basePath: basePath) }

    /// 通信してよいか：この Mac は、いつも。**LAN は、利用者が、その場所を許可しているときだけ**（`approved`：設定 `engineApproved`。大文字小文字は、区別しない）。
    public func isApproved(by approved: String?) -> Bool { isLoopback || approved?.lowercased() == endpoint }

    /// API の根：書かれていれば、それ。なければ、`fallback`（OpenAI 互換は `/v1`）。
    func root(default fallback: String) -> String { basePath.isEmpty ? fallback : basePath }

    /// 経路の書き方（`/v1`・`/openai/v1`）：`/` で始まり、英数字・`.`・`_`・`~`・`-` の部分が続く。`..`・空の部分・`?`・`#` は、不可。
    static func validBasePath(_ path: String) -> Bool {
        guard path.count <= 100, path.range(of: "^(/[A-Za-z0-9._~-]+)+$", options: .regularExpression) != nil else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    /// 画面・鍵の置き場の名前に使う、`ホスト:ポート`。
    public var endpoint: String { "\(host):\(port)" }

    /// この Mac（`127.0.0.1`）か。
    public var isLoopback: Bool { host == Self.loopbackHost }

    public enum Problem: Error, Equatable { case notAllowed(String), invalidPath(String) }

    /// ホストの書き方を検査して、場所にする（**純粋**）。`localhost` は `127.0.0.1` にする。大文字は小文字にする。
    public static func make(host rawHost: String, port: Int, basePath: String = "") throws -> ServerAddress {
        guard basePath.isEmpty || validBasePath(basePath) else { throw Problem.invalidPath(basePath) }
        let host = rawHost.lowercased()
        if host == "localhost" || host == loopbackHost { return .loopback(port: port, basePath: basePath) }
        if let octets = ipv4Octets(host) {
            guard isPrivate(octets) else { throw Problem.notAllowed(rawHost) }
            return ServerAddress(host: host, port: port, basePath: basePath)
        }
        guard host.range(of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.local$", options: .regularExpression) != nil else { throw Problem.notAllowed(rawHost) }
        return ServerAddress(host: host, port: port, basePath: basePath)
    }

    /// `a.b.c.d`（各 0〜255）。書き方が違えば nil（`1.2.3`・`01.2.3.4`・`256.0.0.1` など）。
    static func ipv4Octets(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let value = Int(part), (0...255).contains(value), String(value) == part else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// この Mac・LAN の、私的なアドレスか。
    static func isPrivate(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (127, _): return true                    // この Mac
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true                  // リンクローカル
        case (100, 64...127): return true             // 共有アドレス空間（Tailscale など）
        default: return false
        }
    }

    /// 通信の直前：接続する IPv4 アドレス（文字）。アドレスで書かれていれば、そのまま。`.local` の名前は、引いて、**すべての答えが私的なアドレス**のときだけ。
    /// `lookup`：名前を引く（テストで差し替える）。引けない・IPv4 の答えがない・1 つでも私的でない：失敗。
    func connectHost(lookup: @Sendable (String) async -> [String] = ServerAddress.systemLookup) async throws -> String {
        if Self.ipv4Octets(host) != nil { return host }
        let answers = await lookup(host)
        guard !answers.isEmpty else { throw ChatError.unresolved(host: host) }
        for answer in answers {
            guard let octets = Self.ipv4Octets(answer), Self.isPrivate(octets) else { throw ChatError.notPrivate(host: host, answer: answer) }
        }
        return answers[0]
    }

    /// OS に、名前を引いてもらう（IPv4 だけ）。
    static let systemLookup: @Sendable (String) async -> [String] = { name in
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { continuation.resume(returning: []); return }
                defer { freeaddrinfo(first) }
                var found: [String] = []
                var current: UnsafeMutablePointer<addrinfo>? = first
                while let item = current {
                    if let address = item.pointee.ai_addr, item.pointee.ai_family == AF_INET {
                        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                            var sin = pointer.pointee.sin_addr
                            if inet_ntop(AF_INET, &sin, &buffer, socklen_t(buffer.count)) != nil { found.append(String(cString: buffer)) }
                        }
                    }
                    current = item.pointee.ai_next
                }
                continuation.resume(returning: found)
            }
        }
    }
}

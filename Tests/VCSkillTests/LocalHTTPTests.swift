import Foundation
import Testing
@testable import VCSkill

/// `LocalHTTP`：要求の文と、応答の読み取り（**純粋**）。応答は、作り物。
@Suite struct LocalHTTPTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test func theRequestCarriesTheHostTheKeyAndTheBodyAndNeverANewline() {
        let request = String(decoding: LocalHTTP.requestData(method: "POST", host: "100.82.142.127", port: 28572, path: "/v1/chat/completions",
                                                            headers: [("Authorization", "Bearer k-sample\r\nX-Evil: 1")], body: data("{}")), as: UTF8.self)
        #expect(request.hasPrefix("POST /v1/chat/completions HTTP/1.1\r\nHost: 100.82.142.127:28572\r\nConnection: close\r\n"))
        #expect(request.contains("Authorization: Bearer k-sample") && !request.contains("\r\nX-Evil: 1") && request.contains("Content-Length: 2\r\n\r\n{}"))
    }

    @Test func aResponseEndsByContentLengthByChunksOrByTheConnectionClosing() throws {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        #expect(try LocalHTTP.parse(data(head + "Content-Length: 5\r\n\r\nhello"), atEOF: false) == .init(status: 200, body: data("hello")))
        #expect(try LocalHTTP.parse(data(head + "Content-Length: 5\r\n\r\nhel"), atEOF: false) == nil)                     // まだ、届いている途中
        #expect(throws: LocalHTTP.Failure.malformed("本文が、途中で切れた")) { try LocalHTTP.parse(data(head + "Content-Length: 5\r\n\r\nhel"), atEOF: true) }
        #expect(try LocalHTTP.parse(data(head + "Content-Length: 3\r\n\r\nabcEXTRA"), atEOF: false)?.body == data("abc"))   // 余りは、読まない
        let chunked = head + "Transfer-Encoding: chunked\r\n\r\n"
        #expect(try LocalHTTP.parse(data(chunked + "3\r\nabc\r\n2;ext=1\r\nde\r\n0\r\n\r\n"), atEOF: false)?.body == data("abcde"))
        #expect(try LocalHTTP.parse(data(chunked + "3\r\nabc\r\n2\r\nd"), atEOF: false) == nil)                          // チャンクの途中
        #expect(throws: LocalHTTP.Failure.malformed("チャンクが、途中で切れた")) { try LocalHTTP.parse(data(chunked + "3\r\nabc\r\n2\r\nd"), atEOF: true) }
        #expect(throws: LocalHTTP.Failure.malformed("チャンクの大きさ")) { try LocalHTTP.parse(data(chunked + "zz\r\nabc\r\n0\r\n\r\n"), atEOF: false) }
        #expect(try LocalHTTP.parse(data(head + "\r\nrest"), atEOF: false) == nil)                                           // 終わりの印がない：閉じるまで
        #expect(try LocalHTTP.parse(data(head + "\r\nrest"), atEOF: true) == .init(status: 200, body: data("rest")))
        #expect(try LocalHTTP.parse(data("HTTP/1.1 204 No Content\r\n\r\n"), atEOF: false) == .init(status: 204, body: Data()))   // 本文のない応答
        #expect(try LocalHTTP.parse(data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 2\r\n\r\nno"), atEOF: false) == .init(status: 401, body: data("no")))
        #expect(try LocalHTTP.parse(data("HTTP/1.1 302 Found\r\nLocation: http://elsewhere/\r\nContent-Length: 0\r\n\r\n"), atEOF: false)?.status == 302)   // 追わない
        #expect(throws: LocalHTTP.Failure.malformed("状態の行")) { try LocalHTTP.parse(data("garbage\r\n\r\n"), atEOF: false) }
        #expect(try LocalHTTP.parse(data("HTTP/1.1 200 OK\r\nCont"), atEOF: false) == nil)                                    // ヘッダーの途中
    }
}

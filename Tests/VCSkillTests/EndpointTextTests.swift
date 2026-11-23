import Testing
@testable import VCSkill

/// エンドポイントの文字の形：分け方と、保存する形への整え方（`--engine` と設定ウィンドウが、同じ分け方を使う）。
@Suite struct EndpointTextTests {
    @Test func aTextIsSplitIntoSchemeAuthorityAndPath() {
        #expect(EndpointText.parts("http://192.168.1.5:8080/v1/") == .init(scheme: "http", authority: "192.168.1.5:8080", path: "/v1"))
        #expect(EndpointText.parts(" 8000 ") == .init(scheme: nil, authority: "8000", path: ""))
        #expect(EndpointText.parts("HTTPS://Box.local/openai/v1") == .init(scheme: "https", authority: "Box.local", path: "/openai/v1"))
        #expect(EndpointText.parts("8000//") == .init(scheme: nil, authority: "8000", path: ""))
    }

    @Test func aPastedUrlBecomesTheStoredFormAndOnlyHttpIsSupported() {
        for (input, expected) in [("8000", "8000"), (" 127.0.0.1:8000 ", "127.0.0.1:8000"), ("http://192.168.1.5:8080", "192.168.1.5:8080"), ("http://192.168.1.5:8080/v1", "192.168.1.5:8080/v1"),
                                  ("HTTP://Box.local:8000/v2/", "Box.local:8000/v2"), ("http://127.0.0.1:8000/", "127.0.0.1:8000"), ("http://box.local/openai/v1", "box.local:80/openai/v1"), ("http://192.168.1.5", "192.168.1.5:80")] {
            #expect(EndpointText.canonical(input).value == expected && EndpointText.canonical(input).unsupportedScheme == nil, "\(input)")
        }
        #expect(EndpointText.canonical("https://192.168.1.5:8080").unsupportedScheme == "https")
        #expect(EndpointText.canonical("ftp://x:21").unsupportedScheme == "ftp" && EndpointText.canonical("ftp://x:21").value == "ftp://x:21")   // 保存する形にできない：入力のまま
    }
}

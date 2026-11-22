import Testing
@testable import VCSkill

/// `--engine`：エンジンの書き方。通信先は、この Mac と、同じ LAN だけ（インターネットのホストは、書けない）。
@Suite struct EngineTests {
    @Test func theEngineIsAppleOllamaOrOpenAICompatible() throws {
        #expect(try Engine.parse("apple") == .apple)
        #expect(try Engine.parse("ollama:qwen3.5:4b") == .ollama(model: "qwen3.5:4b", server: Engine.ollamaDefault))   // モデル名の `:` は、そのまま。場所を省くと、既定
        #expect(try Engine.parse("ollama:qwen2.5") == .ollama(model: "qwen2.5", server: .loopback(port: 11434)))
        #expect(try Engine.parse("openai:qwen3-4b@1234") == .openAI(model: "qwen3-4b", server: .loopback(port: 1234)))
        #expect(try Engine.parse("openai:org/model:q4@8080") == .openAI(model: "org/model:q4", server: .loopback(port: 8080)))
    }

    /// Ollama も、場所を書ける（省くと、既定の `127.0.0.1:11434`）。LAN は、OpenAI 互換と同じ規則。
    @Test func anOllamaEndpointIsOptionalAndFollowsTheSameNetworkRules() throws {
        #expect(try Engine.parse("ollama:qwen3.5:4b@11435") == .ollama(model: "qwen3.5:4b", server: .loopback(port: 11435)))
        let lan = try Engine.parse("ollama:qwen3.5:4b@192.168.1.5:11434")
        #expect(lan == .ollama(model: "qwen3.5:4b", server: try ServerAddress.make(host: "192.168.1.5", port: 11434)) && lan.talksOverLAN && lan.serverEndpoint == "192.168.1.5:11434")
        #expect(!(try Engine.parse("ollama:m")).talksOverLAN && Engine.apple.server == nil && Engine.apple.serverEndpoint == nil)
        #expect(throws: Engine.ParseError.invalidHost("8.8.8.8")) { try Engine.parse("ollama:m@8.8.8.8:11434") }
        #expect(throws: Engine.ParseError.invalidPort("x")) { try Engine.parse("ollama:m@x") }
        #expect(throws: Engine.ParseError.invalidPort("")) { try Engine.parse("ollama:m@") }
        #expect(throws: Engine.ParseError.cloudModel("m-cloud")) { try Engine.parse("ollama:m-cloud@192.168.1.5:11434") }
    }

    @Test func unknownEnginesBadNamesAndCloudModelsAreRefused() {
        #expect(throws: Engine.ParseError.unknown("openrouter:gpt")) { try Engine.parse("openrouter:gpt") }
        #expect(throws: Engine.ParseError.invalidModel("")) { try Engine.parse("ollama:") }
        #expect(throws: Engine.ParseError.invalidModel("a b")) { try Engine.parse("ollama:a b") }
        // クラウドで動くモデルは、入力を外へ出す：使えない（Ollama・OpenAI 互換の、どちらでも）
        #expect(throws: Engine.ParseError.cloudModel("gpt-oss:120b-cloud")) { try Engine.parse("ollama:gpt-oss:120b-cloud") }
        #expect(throws: Engine.ParseError.cloudModel("Qwen3-Coder:480B-Cloud")) { try Engine.parse("ollama:Qwen3-Coder:480B-Cloud") }
        #expect(throws: Engine.ParseError.cloudModel("m-cloud")) { try Engine.parse("openai:m-cloud@1234") }
    }

    /// OpenAI 互換の場所：`<ポート>`（この Mac）か `<ホスト>:<ポート>`（同じ LAN）。インターネットのホストは、書けない。
    @Test func theOpenAIPlaceIsAPortOrALANHostWithAPort() throws {
        #expect(throws: Engine.ParseError.invalidPort("")) { try Engine.parse("openai:m") }
        #expect(throws: Engine.ParseError.invalidPort("example.com")) { try Engine.parse("openai:m@example.com") }
        #expect(throws: Engine.ParseError.invalidPort("0")) { try Engine.parse("openai:m@0") }
        #expect(throws: Engine.ParseError.invalidPort("70000")) { try Engine.parse("openai:m@70000") }
        let lan = try Engine.parse("openai:qwen@192.168.1.5:8080")
        #expect(lan == .openAI(model: "qwen", server: try ServerAddress.make(host: "192.168.1.5", port: 8080)) && lan.talksOverLAN && lan.serverEndpoint == "192.168.1.5:8080")
        #expect(try Engine.parse("openai:m@Mac-Studio.local:8000") == .openAI(model: "m", server: try ServerAddress.make(host: "mac-studio.local", port: 8000)))
        let here = try Engine.parse("openai:m@localhost:8000")
        #expect(here == .openAI(model: "m", server: .loopback(port: 8000)) && !here.talksOverLAN)       // この Mac は、LAN ではない
        for host in ["evil.example", "8.8.8.8", "172.32.0.1", "192.169.1.1", "100.128.0.1", "[::1]", "fe80::1", "1.2.3", "010.0.0.1", "example.local.evil.com"] {
            #expect(throws: Engine.ParseError.invalidHost(host)) { try Engine.parse("openai:m@\(host):1234") }
        }
        #expect(throws: Engine.ParseError.cloudModel("m-cloud")) { try Engine.parse("openai:m-cloud@192.168.1.5:1234") }   // LAN でも、クラウドのモデルは、使えない
    }

    @Test func theBuiltInAdaptersStartOnLocalhost() {
        #expect(OllamaChat(model: "m").server.endpoint == "127.0.0.1:11434")
        #expect(OpenAICompatibleChat(model: "m", port: 1234).server.endpoint == "127.0.0.1:1234")
        #expect(Engine.apple.makeChat() == nil)
    }
}

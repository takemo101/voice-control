import Testing
@testable import VCSkill

/// `--engine`：エンジンの書き方。通信先は、この Mac の 127.0.0.1 だけ（ホストは書けない）。
@Suite struct EngineTests {
    @Test func theEngineIsAppleOllamaOrOpenAICompatible() throws {
        #expect(try Engine.parse("apple") == .apple)
        #expect(try Engine.parse("ollama:qwen3.5:4b") == .ollama(model: "qwen3.5:4b"))   // モデル名の `:` は、そのまま
        #expect(try Engine.parse("ollama:qwen2.5") == .ollama(model: "qwen2.5"))
        #expect(try Engine.parse("openai:qwen3-4b@1234") == .openAI(model: "qwen3-4b", port: 1234))
        #expect(try Engine.parse("openai:org/model:q4@8080") == .openAI(model: "org/model:q4", port: 8080))
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

    /// OpenAI 互換は、ポートだけを書く。ホストを書けない（`@` のあとは、数だけ）ので、外のサーバーへは向けられない。
    @Test func theOpenAIPortMustBeANumberAndTheHostCannotBeWritten() {
        #expect(throws: Engine.ParseError.invalidPort("")) { try Engine.parse("openai:m") }
        #expect(throws: Engine.ParseError.invalidPort("example.com")) { try Engine.parse("openai:m@example.com") }
        #expect(throws: Engine.ParseError.invalidPort("evil.example:1234")) { try Engine.parse("openai:m@evil.example:1234") }
        #expect(throws: Engine.ParseError.invalidPort("0")) { try Engine.parse("openai:m@0") }
        #expect(throws: Engine.ParseError.invalidPort("70000")) { try Engine.parse("openai:m@70000") }
    }

    @Test func everyAdapterTalksOnlyToLocalhost() {
        #expect(OllamaChat(model: "m").server.endpoint == "127.0.0.1:11434")
        #expect(OpenAICompatibleChat(model: "m", port: 1234).server.endpoint == "127.0.0.1:1234")
        #expect(Engine.apple.makeChat() == nil)
    }
}

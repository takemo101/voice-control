import Foundation
import Testing
@testable import VCSkill

/// 通信の形の変換（Ollama・OpenAI 互換）。通信は、しない（変換だけを、確かめる）。
@Suite struct ChatAdapterTests {
    private let conversation: [ChatMessage] = [
        ChatMessage(role: .system, content: "sys"),
        ChatMessage(role: .user, content: "User request: x"),
        ChatMessage(role: .assistant, toolCalls: [.init(id: "call_1", name: "run_command", arguments: ["command": "pbpaste"])]),
        ChatMessage(role: .tool, content: "exit 0\nhello", toolCallID: "call_1", toolName: "run_command"),
    ]

    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    @Test func theToolDescriptionCarriesNoExampleCommands() throws {
        // 例があると、モデルが、スキルの手順より例に引きずられた（測定）
        let text = String(decoding: try json(ChatTools.runCommand), as: UTF8.self)
        #expect(!text.contains("agent-desktop") && !text.contains("open -a") && text.contains("run_command"))
    }

    @Test func ollamaGetsArgumentsAsAnObjectAndTheToolNameOnTheResult() throws {
        let body = OllamaChat.request(model: "m", messages: conversation)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let call = try #require(((messages[2]["tool_calls"] as? [[String: Any]])?.first?["function"]) as? [String: Any])
        #expect((call["arguments"] as? [String: String]) == ["command": "pbpaste"])
        #expect(messages[3]["tool_name"] as? String == "run_command" && messages[3]["tool_call_id"] == nil)
        #expect(body["think"] as? Bool == false)
    }

    @Test func openAIGetsArgumentsAsAJSONStringAndTheCallIdOnTheResult() throws {
        let body = OpenAICompatibleChat.request(model: "m", messages: conversation)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let call = try #require((messages[2]["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_1" && call["type"] as? String == "function")
        let arguments = try #require((call["function"] as? [String: Any])?["arguments"] as? String)
        #expect(arguments == #"{"command":"pbpaste"}"#)
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
        #expect(body["reasoning_effort"] as? String == "none")   // 考えさせない（遅くなる）
    }

    @Test func aToolCallIsReadFromBothWireFormats() throws {
        let ollama = try json(["message": ["role": "assistant", "content": "", "tool_calls": [["function": ["name": "run_command", "arguments": ["command": "pbpaste", "n": 3, "flag": true]]]]]])
        let a = try OllamaChat.reply(from: ollama)
        #expect(a.toolCalls == [.init(id: nil, name: "run_command", arguments: ["command": "pbpaste", "n": "3", "flag": "true"])])

        let openAI = try json(["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call_9", "type": "function", "function": ["name": "run_command", "arguments": #"{"command":"pbpaste"}"#]]]]]]])
        let b = try OpenAICompatibleChat.reply(from: openAI)
        #expect(b.toolCalls == [.init(id: "call_9", name: "run_command", arguments: ["command": "pbpaste"])] && b.content == "")
    }

    @Test func aPlainReplyAndBrokenResponsesAreHandled() throws {
        #expect(try OllamaChat.reply(from: json(["message": ["content": "done: ok"]])).content == "done: ok")
        #expect(try OpenAICompatibleChat.reply(from: json(["choices": [["message": ["content": "done: ok"]]]])).content == "done: ok")
        #expect(throws: ChatError.self) { try OllamaChat.reply(from: Data("not json".utf8)) }
        #expect(throws: ChatError.self) { try OpenAICompatibleChat.reply(from: json(["choices": []])) }
        // 引数が壊れた JSON でも、空の引数として返す（実行者が、「command がない」と、モデルへ返す）
        let broken = try json(["choices": [["message": ["tool_calls": [["id": "c", "function": ["name": "run_command", "arguments": "{oops"]]]]]]])
        #expect(try OpenAICompatibleChat.reply(from: broken).toolCalls.first?.arguments == [:])
    }
}

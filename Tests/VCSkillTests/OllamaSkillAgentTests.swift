import Foundation
import Testing
@testable import VCSkill

/// `--engine ollama:<モデル>`：エンジンの書き方と、Ollama のモデルで、スキルを実行する流れ（偽の Ollama）。許可の照合は、Apple のモデルと同じ `CommandSession`。
@Suite struct EngineTests {
    @Test func theEngineIsAppleOrOllamaWithTheModelNameKeepingItsOwnColon() throws {
        #expect(try Engine.parse("apple") == .apple)
        #expect(try Engine.parse("ollama:qwen3.5:4b") == .ollama(model: "qwen3.5:4b"))
        #expect(try Engine.parse("ollama:qwen2.5") == .ollama(model: "qwen2.5"))
    }

    @Test func unknownEnginesBadNamesAndCloudModelsAreRefused() {
        #expect(throws: Engine.ParseError.unknown("openai:gpt")) { try Engine.parse("openai:gpt") }
        #expect(throws: Engine.ParseError.invalidModel("")) { try Engine.parse("ollama:") }
        #expect(throws: Engine.ParseError.invalidModel("a b")) { try Engine.parse("ollama:a b") }
        // クラウドで動くモデルは、入力を外へ出す：使えない
        #expect(throws: Engine.ParseError.cloudModel("gpt-oss:120b-cloud")) { try Engine.parse("ollama:gpt-oss:120b-cloud") }
        #expect(throws: Engine.ParseError.cloudModel("Qwen3-Coder:480B-Cloud")) { try Engine.parse("ollama:Qwen3-Coder:480B-Cloud") }
    }
}

@Suite struct OllamaSkillAgentTests {
    /// 決まった返事を、順に返す偽の Ollama。受け取ったやりとりを、記録する。
    private final class Script: OllamaChatting, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [OllamaMessage]
        private(set) var received: [[OllamaMessage]] = []
        init(_ replies: [OllamaMessage]) { self.replies = replies }
        func chat(model: String, messages: [OllamaMessage]) async throws -> OllamaMessage {
            lock.lock(); defer { lock.unlock() }
            received.append(messages)
            return replies.isEmpty ? OllamaMessage(role: "assistant", content: "done: 終わり") : replies.removeFirst()
        }
    }

    private func call(_ command: String) -> OllamaMessage {
        OllamaMessage(role: "assistant", tool_calls: [.init(function: .init(name: "run_command", arguments: ["command": command]))])
    }
    private func said(_ text: String) -> OllamaMessage { OllamaMessage(role: "assistant", content: text) }

    private func agent(_ script: Script, allowed: [String] = ["echo"], dryRun: Bool = false) -> (OllamaSkillAgent, Events) {
        let events = Events()
        let display = ExecutionDisplay(onCommand: { events.add("command \($0)") }, onResult: { code, out in events.add("result \(code) \(out)") }, onDenied: { cmd, _ in events.add("denied \(cmd)") })
        let skill = Skill(name: "demo", description: "x", allowedCommands: allowed, confirm: false, body: "Run echo hello.", file: URL(fileURLWithPath: "/tmp/demo/SKILL.md"))
        return (OllamaSkillAgent(skill: skill, model: "m", dryRun: dryRun, display: display, client: script), events)
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @Test func anAllowedCommandIsRunAndItsOutputGoesBackToTheModel() async throws {
        let script = Script([call("echo hello"), said("done: 挨拶しました")])
        let (agent, events) = agent(script)
        #expect(try await agent.run(request: "挨拶して") == "done: 挨拶しました")
        #expect(agent.executedCommands == ["echo hello"])
        #expect(events.all == ["command echo hello", "result 0 hello\n"])
        let tool = script.received.last?.last
        #expect(tool?.role == "tool" && tool?.content == "exit 0\nhello\n" && tool?.tool_name == "run_command")
        #expect(script.received.first?.first?.role == "system")
    }

    /// 許可にないコマンドは、実行せず、エラーをモデルへ返す（モデルが何を言っても、許可はコードが決める）。
    @Test func aCommandOutsideTheAllowListIsNotRunAndTheModelIsTold() async throws {
        let script = Script([call("rm -rf /tmp/x"), said("failed: できません")])
        let (agent, events) = agent(script)
        _ = try await agent.run(request: "消して")
        #expect(agent.executedCommands.isEmpty)
        #expect(events.all == ["denied rm -rf /tmp/x"])
        #expect(script.received.last?.last?.content.hasPrefix("ERROR: not allowed") == true)
    }

    @Test func aToolCallWithoutTheCommandArgumentGetsAnErrorBack() async throws {
        let script = Script([OllamaMessage(role: "assistant", tool_calls: [.init(function: .init(name: "run_command", arguments: [:]))]), said("failed: x")])
        let (agent, _) = agent(script)
        _ = try await agent.run(request: "x")
        #expect(agent.executedCommands.isEmpty)
        #expect(script.received.last?.last?.content.hasPrefix("ERROR: use the tool run_command") == true)
    }

    /// 道具を使わずに答えたら、1 回だけ、使うよう促す。促したあとも使わなければ、その答えを返す（無限に促さない）。
    @Test func aModelThatAnswersWithoutTheToolIsNudgedOnlyOnce() async throws {
        let script = Script([said("貼り付けてください"), said("まだ答えます")])
        let (agent, _) = agent(script)
        #expect(try await agent.run(request: "x") == "まだ答えます")
        #expect(script.received.count == 2)
        #expect(script.received[1].last?.role == "user" && script.received[1].last?.content.contains("Call the tool run_command") == true)
    }

    @Test func thinkingPartsAreRemovedFromTheReply() async throws {
        let (agent, _) = agent(Script([call("echo hi"), said("<think>\n考え中\n</think>\n\ndone: できた")]))
        #expect(try await agent.run(request: "x") == "done: できた")
    }

    /// dry-run：コマンドは表示するだけで、実行しない。
    @Test func aDryRunShowsTheCommandWithoutRunningIt() async throws {
        let script = Script([call("echo hi"), said("done: x")])
        let (agent, events) = agent(script, dryRun: true)
        _ = try await agent.run(request: "x")
        #expect(agent.executedCommands.isEmpty)
        #expect(events.all == ["command echo hi"])
    }

    /// 呼び出しが止まらなくても、上限で終わる。
    @Test func aModelThatNeverStopsCallingTheToolEndsAtTheLimit() async throws {
        let script = Script(Array(repeating: call("echo again"), count: 100))
        let (agent, _) = agent(script)
        #expect(try await agent.run(request: "x").hasPrefix("failed:"))
        #expect(script.received.count == CommandSession.maxCommands + 4)
    }
}

import Foundation
import VCCore

/// Ollama（この Mac のローカルのモデル）で、スキルを実行する。`SkillAgent`（Apple のモデル）と同じ：**`run_command` という道具 1 つだけ**で、コマンドを実行させる。
/// 許可の照合・出力の整形・コマンド数の上限・取りやめは、`CommandSession` が持つ（どのモデルでも同じ）。
final class OllamaSkillAgent: SkillExecuting, @unchecked Sendable {
    private let session: CommandSession
    private let model: String
    private let client: OllamaChatting

    init(skill: Skill, model: String, dryRun: Bool, display: ExecutionDisplay, cancel: CancelToken? = nil, client: OllamaChatting = OllamaClient.live) {
        session = CommandSession(skill: skill, dryRun: dryRun, display: display, cancel: cancel)
        self.model = model
        self.client = client
    }

    var executedCommands: [String] { session.executedCommands }

    func run(request: String) async throws -> String {
        try session.checkCancelled()
        var messages = [OllamaMessage(role: "system", content: session.instructions), OllamaMessage(role: "user", content: "User request: \(request)")]
        var toolCalls = 0
        var nudged = false
        // 呼び出しの上限：コマンドの上限（`CommandSession` が、超えたら、エラーを返す）に、少し足す
        for _ in 0..<(CommandSession.maxCommands + 4) {
            let reply = try await client.chat(model: model, messages: messages)
            try session.checkCancelled()
            if let calls = reply.tool_calls, !calls.isEmpty {
                messages.append(reply)
                for call in calls {
                    toolCalls += 1
                    let output: String
                    if call.function.name == "run_command", let command = call.function.arguments["command"] { output = session.execute(command) }
                    else { output = "ERROR: use the tool run_command with the argument `command`." }
                    messages.append(OllamaMessage(role: "tool", content: output, tool_name: call.function.name))
                }
                continue
            }
            let text = Self.withoutThinking(reply.content)
            // 道具を 1 回も使わずに答えたら、1 回だけ、使うよう促す（小さいモデルは、「貼り付けてください」などと、答えてしまうことがある。測定）
            if toolCalls == 0 && !nudged {
                nudged = true
                messages.append(OllamaMessage(role: "assistant", content: reply.content))
                messages.append(OllamaMessage(role: "user", content: "Do not answer yet. Call the tool run_command now and run the command that the SKILL tells you to run first."))
                continue
            }
            try session.checkCancelled()
            return session.openAsNoteIfRequested(text)
        }
        return "failed: コマンドの回数が上限に達しました"
    }

    /// 考えの部分（`<think>…</think>`）を除く。
    static func withoutThinking(_ text: String) -> String {
        text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

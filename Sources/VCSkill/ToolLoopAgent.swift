import Foundation
import VCCore
import VCDecision

/// `ChatModel`（Ollama・OpenAI 互換のアダプター）のモデルで、スキルを実行する。Apple のモデル（`SkillAgent`）と同じ：**`run_command` という道具 1 つだけ**で、コマンドを実行させる。
/// 許可の照合・出力の整形・コマンド数の上限・取りやめは、`CommandSession` が持つ（どのモデルでも同じ）。
/// 持つのは、不変のもの（`session`・`chat`）だけ。可変な状態は、`CommandSession` が、ロックで守る。
final class ToolLoopAgent: SkillExecuting {
    private let session: CommandSession
    private let chat: ChatModel

    init(skill: Skill, chat: ChatModel, dryRun: Bool, display: ExecutionDisplay, cancel: CancelToken? = nil, scorer: (@Sendable () -> OptionScorer?)? = nil) {
        session = CommandSession(skill: skill, dryRun: dryRun, display: display, cancel: cancel, scorer: scorer)
        self.chat = chat
    }

    var executedCommands: [String] { session.executedCommands }

    func run(request: String) async throws -> String {
        try session.checkCancelled()
        session.begin(request: request)
        var messages = [ChatMessage(role: .system, content: session.instructions), ChatMessage(role: .user, content: "User request: \(request)")]
        var toolCallCount = 0
        var nudged = false
        // 呼び出しの上限：コマンドの上限（`CommandSession` が、超えたら、エラーを返す）に、少し足す
        for _ in 0..<(CommandSession.maxCommands + 4) {
            let reply = try await chat.chat(messages)
            try session.checkCancelled()
            if !reply.toolCalls.isEmpty {
                messages.append(reply)
                for call in reply.toolCalls {
                    toolCallCount += 1
                    let output: String
                    if call.name == "run_command", let command = call.arguments["command"] { output = session.execute(command) }
                    else { output = "ERROR: use the tool run_command with the argument `command`." }
                    messages.append(ChatMessage(role: .tool, content: output, toolCallID: call.id, toolName: call.name))
                }
                continue
            }
            // 道具を 1 回も使わずに答えたら、1 回だけ、使うよう促す（小さいモデルは、「貼り付けてください」などと、答えてしまうことがある。測定）
            if toolCallCount == 0 && !nudged {
                nudged = true
                messages.append(ChatMessage(role: .assistant, content: reply.content))
                messages.append(ChatMessage(role: .user, content: "Do not answer yet. Call the tool run_command now and run the command that the SKILL tells you to run first."))
                continue
            }
            return session.openAsNoteIfRequested(Self.withoutThinking(reply.content))
        }
        return "failed: コマンドの回数が上限に達しました"
    }

    /// 考えの部分（`<think>…</think>`）を除く。
    static func withoutThinking(_ text: String) -> String {
        text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import FoundationModels
import Foundation
import VCCore

/// Apple の言語モデル（FoundationModels）で、スキルを実行する。**`run_command` という道具 1 つだけ**で、コマンドを実行させる。
/// 持つのは、不変の `session` だけ（可変な状態は、`CommandSession` が、ロックで守る）。
final class SkillAgent: SkillExecuting {
    private let session: CommandSession

    init(skill: Skill, dryRun: Bool, display: ExecutionDisplay, cancel: CancelToken? = nil) {
        session = CommandSession(skill: skill, dryRun: dryRun, display: display, cancel: cancel)
    }

    var executedCommands: [String] { session.executedCommands }

    /// 返事（`done: …` / `failed: …`。`result: markdown-note` のスキルは、メモを開いたあとの `done: …`）。
    func run(request: String) async throws -> String {
        try session.checkCancelled()
        let model = LanguageModelSession(tools: [RunCommandTool(session)], instructions: session.instructions)
        let reply = try await model.respond(to: "User request: \(request)").content
        try session.checkCancelled()
        return session.openAsNoteIfRequested(reply)
    }
}

struct RunCommandTool: Tool {
    let name = "run_command"
    let description = "Run one shell-free command line (for example: agent-desktop snapshot -i) and get its exit code and output."
    let session: CommandSession
    init(_ session: CommandSession) { self.session = session }

    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(name: "RunCommandArgs", description: "arguments", properties: [
            .init(name: "command", description: "the full command line, e.g. open -a Spotify", schema: DynamicGenerationSchema(type: String.self), isOptional: false),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        session.execute(try arguments.value(String.self, forProperty: "command"))
    }
}

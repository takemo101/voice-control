import FoundationModels
import Foundation
import VCCore

/// スキルの実行。Apple の言語モデル（FoundationModels）に、スキルの本文と依頼文を渡し、**`run_command` という道具 1 つだけ**で、コマンドを実行させる。
/// - 実行してよいのは、スキルの `allowed-commands` に一致するものだけ（`CommandPolicy`）。シェルは使わない。
/// - 実行するコマンドと結果は、すべて、`onCommand`・`onResult` で、画面に出す。
/// - `dryRun` なら、何も実行しない（どんなコマンドを実行しようとするかだけを見る）。
public final class SkillAgent: @unchecked Sendable {
    public static let maxCommands = 15

    public struct Display: Sendable {
        public var onCommand: @Sendable (String) -> Void
        public var onResult: @Sendable (_ exitCode: Int32, _ output: String) -> Void
        public var onDenied: @Sendable (_ command: String, _ reason: String) -> Void
        public init(onCommand: @escaping @Sendable (String) -> Void, onResult: @escaping @Sendable (Int32, String) -> Void, onDenied: @escaping @Sendable (String, String) -> Void) {
            self.onCommand = onCommand; self.onResult = onResult; self.onDenied = onDenied
        }
    }

    let skill: Skill
    let dryRun: Bool
    let display: Display
    /// 取りやめの合図（Esc）。取りやめられたら、実行中のコマンドを止め、以降のコマンドは実行しない。
    let cancel: CancelToken?
    let aliases = RefAliases()
    private let lock = NSLock()
    private var count = 0
    private var log: [String] = []

    public init(skill: Skill, dryRun: Bool, display: Display, cancel: CancelToken? = nil) {
        self.skill = skill; self.dryRun = dryRun; self.display = display; self.cancel = cancel
    }

    /// 実行したコマンド（拒否したものを除く）。
    public var executedCommands: [String] { lock.lock(); defer { lock.unlock() }; return log }

    func nextCall() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    func record(_ c: String) { lock.lock(); log.append(c); lock.unlock() }

    private var instructions: String {
        """
        You carry out the user's request by running shell commands ONLY through the tool `run_command`. Never answer with commands in text.
        Allowed commands (the command line must start with one of these): \(skill.allowedCommands.joined(separator: " | ")).
        Commands run WITHOUT a shell: no pipes, redirects, `&&`, `;` or `$(...)`. Quote arguments that contain spaces. Run one command at a time and read its output before the next.
        Do exactly what the SKILL says; do nothing else. Never invent text to type: use only text the user actually said.
        If a command fails, read the error, fix the command, and try again (at most twice) before giving up.
        When finished, reply with: done: <one short sentence in Japanese>. If you cannot, reply: failed: <reason in Japanese>.

        SKILL (\(skill.name)):
        \(skill.body)
        """
    }

    /// 返事（`done: …` / `failed: …`）。
    public func run(request: String) async throws -> String {
        try checkCancelled()
        let session = LanguageModelSession(tools: [RunCommandTool(self)], instructions: instructions)
        let reply = try await session.respond(to: "User request: \(request)").content
        try checkCancelled()
        return reply
    }

    /// 取りやめられていれば、`CancellationError` を投げる。
    func checkCancelled() throws {
        if cancel?.isCancelled == true { throw CancellationError() }
        try Task.checkCancellation()
    }

    fileprivate func execute(_ command: String) -> String {
        if cancel?.isCancelled == true { return "ERROR: cancelled by the user. Stop now and do not run more commands." }
        let n = nextCall()
        if n > Self.maxCommands { return "ERROR: too many commands (limit \(Self.maxCommands)). Stop now and reply: failed: <reason>" }
        let argv: [String]
        switch CommandPolicy.tokenize(command) {
        case .failure(let v): display.onDenied(command, v.reason); return "ERROR: \(v.reason)"
        case .success(let tokens): argv = tokens
        }
        if let violation = CommandPolicy.check(argv: argv, allowed: skill.allowedCommands) {
            display.onDenied(command, violation.reason)
            return "ERROR: not allowed — \(violation.reason)"
        }
        display.onCommand(command)
        if dryRun { return "(dry-run) not executed. Assume it succeeded and continue; reply done when the SKILL's steps are listed." }
        record(command)
        let result = CommandRunner.run(argv: argv.map(aliases.expand), cancel: cancel)
        let compact = OutputCompactor.compact(argv: argv, output: result.output, aliases: aliases)
        display.onResult(result.exitCode, compact)
        return "exit \(result.exitCode)\(result.timedOut ? " (timed out)" : "")\n\(compact)"
    }
}

struct RunCommandTool: Tool {
    let name = "run_command"
    let description = "Run one shell-free command line (for example: agent-desktop snapshot -i) and get its exit code and output."
    let agent: SkillAgent
    init(_ agent: SkillAgent) { self.agent = agent }

    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(name: "RunCommandArgs", description: "arguments", properties: [
            .init(name: "command", description: "the full command line, e.g. open -a Spotify", schema: DynamicGenerationSchema(type: String.self), isOptional: false),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        agent.execute(try arguments.value(String.self, forProperty: "command"))
    }
}

import Foundation
import VCCore
import VCDecision

/// スキルの実行で、モデルが呼ぶ「コマンドを 1 つ実行する」道具の中身（どのモデルでも共通）。
/// - 実行してよいのは、スキルの `allowed-commands` に一致するものだけ（`CommandPolicy`）。シェルは使わない。
/// - 実行するコマンドと結果は、すべて、`display` で画面に出す。出力は、`OutputCompactor` で短くして、モデルへ返す。
/// - `dryRun` なら、何も実行しない（どんなコマンドを実行しようとするかだけを見る）。
/// `@unchecked Sendable` の理由：可変な状態（`count`・`log`）は、すべて `lock` で守る。ほかの保持物は、不変（`let`）か、Sendable。
final class CommandSession: @unchecked Sendable {
    static let maxCommands = 15

    let skill: Skill
    let dryRun: Bool
    let display: ExecutionDisplay
    /// 取りやめの合図（Esc）。取りやめられたら、実行中のコマンドを止め、以降のコマンドは実行しない。
    let cancel: CancelToken?
    let aliases = RefAliases()
    /// この実行の、直前の候補（`vc find`・`vc pick` が使う）。
    let memory = OptionMemory()
    /// この実行の中で、加工中の画像（`vc image` が、続けて加工できるように）。
    private let working = WorkingImage()
    /// Tiny-Jev（使うときまで、読み込まない）。`vc pick` が使う。
    private let scorer: (@Sendable () -> OptionScorer?)?
    /// 画像を見るモデル（`vc see`）：実行しているスキルと、同じエンジン。
    private let engine: Engine
    private let lock = NSLock()
    private var count = 0
    private var log: [String] = []
    private var request = ""
    private var document: String?
    private var image: URL?
    var spotlight: FileSearch.Spotlight = FileSearch.live
    /// いまのスクリーンショットのパス（`${SCREENSHOT}`）。撮っていない・古いときは nil。テストで、差し替える。
    var screenshotPath: @Sendable () -> String? = { if case let .success(url) = ScreenshotStore.current() { return url.path } else { return nil } }

    init(skill: Skill, dryRun: Bool, display: ExecutionDisplay, cancel: CancelToken?, scorer: (@Sendable () -> OptionScorer?)? = nil, engine: Engine = .apple) {
        self.skill = skill; self.dryRun = dryRun; self.display = display; self.cancel = cancel; self.scorer = scorer; self.engine = engine
    }

    /// `vc see` の答え（Markdown）。あれば、`SkillRunner` が、ウィンドウに出す（言語モデルに、長い文を写させない：写し間違い・省略をしない）。
    /// `vc image` が保存した画像（最後のもの）。
    var producedImage: URL? { lock.lock(); defer { lock.unlock() }; return image }

    var producedDocument: String? { lock.lock(); defer { lock.unlock() }; return document }

    /// 利用者の依頼の文（`vc pick` の、何を選ぶかの既定）。実行の前に、呼ぶ。
    /// いまの依頼（`instructions` の `${USER_REQUEST}` に使う）。
    private var currentRequest: String { lock.lock(); defer { lock.unlock() }; return request }

    func begin(request: String) { lock.lock(); self.request = request; lock.unlock() }

    /// 実行したコマンド（拒否したものを除く）。
    var executedCommands: [String] { lock.lock(); defer { lock.unlock() }; return log }

    /// 道具（`run_command`）を、これまでに呼んだ回数（許可されなかった呼び出しも数える）。
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// 小さなモデルは、道具を呼ばずに、道具の呼び出しの「文字」（`run_command{command: "open"}`）や、「貼り付けてください」などを返すことがある。
    /// 道具を 1 回も呼ばず、返事が `done`・`failed`・`skip` で始まらないとき、1 回だけ、道具を呼ぶよう促す（どのモデルでも共通）。
    static func shouldNudge(callCount: Int, reply: String) -> Bool {
        guard callCount == 0 else { return false }
        let head = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !(head.hasPrefix("done") || head.hasPrefix("failed") || head.hasPrefix("skip"))
    }

    static let nudgeText = "Do not answer yet. Call the tool run_command now and run the command that the SKILL tells you to run first."

    private func nextCall() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    private func record(_ c: String) { lock.lock(); log.append(c); lock.unlock() }

    /// 取りやめられていれば、`CancellationError` を投げる。
    func checkCancelled() throws {
        if cancel?.isCancelled == true { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// コマンドを 1 つ実行して、モデルへ返す文字（終了コードと、短くした出力。拒否・上限・取りやめは、`ERROR: …`）。
    func execute(_ command: String) -> String {
        if cancel?.isCancelled == true { return "ERROR: cancelled by the user. Stop now and do not run more commands." }
        let n = nextCall()
        if n > Self.maxCommands { return "ERROR: too many commands (limit \(Self.maxCommands)). Stop now and reply: failed: <reason>" }
        var command = command
        var argv: [String]
        switch CommandPolicy.tokenize(command) {
        case .failure(let v): display.onDenied(command, v.reason); return "ERROR: \(v.reason)"
        case .success(let tokens): argv = tokens
        }
        // 許可の先頭（`osascript …/spotify.applescript`）を落として、引数だけ書いたとき（Apple のモデルが、よくする）：許可が 1 項目だけのスキルは、先頭を補う（画面には、補ったあとのコマンドを出す）
        if let completed = CommandPolicy.completed(command: command, argv: argv, allowed: skill.allowedCommands) {
            command = completed.command
            argv = completed.argv
        }
        if let violation = CommandPolicy.check(argv: argv, allowed: skill.allowedCommands) {
            display.onDenied(command, violation.reason)
            return "ERROR: not allowed — \(violation.reason)"
        }
        display.onCommand(command)
        if dryRun { return "(dry-run) not executed. Assume it succeeded and continue; reply done when the SKILL's steps are listed." }
        record(command)
        // `vc find`・`vc pick` は、`vc` 自身が処理する（外のプロセスを起こさない）
        if InternalCommands.handles(argv) {
            lock.lock(); let current = request; lock.unlock()
            var commands = InternalCommands(request: current, scorer: scorer, memory: memory, spotlight: spotlight)
            commands.engine = engine; commands.cancel = cancel
            commands.images.working = working
            let result = commands.run(argv)
            display.onResult(result.exitCode, result.text)
            if let saved = result.image { lock.lock(); image = saved; lock.unlock() }
            // `vc see` の答えは、ウィンドウに出すので、言語モデルには、短い知らせだけ返す（長い文を、写させない）
            if let answer = result.document {
                lock.lock(); document = answer; lock.unlock()
                return "exit 0\nThe answer (\(answer.count) characters) is shown to the user in a window. Do not repeat it. Reply now: done: 結果をウィンドウに表示しました"
            }
            return "exit \(result.exitCode)\n\(result.text)"
        }
        let result = CommandRunner.run(argv: argv.map(aliases.expand), timeout: skill.commandTimeout, cancel: cancel)
        let compact = OutputCompactor.compact(argv: argv, output: result.output, aliases: aliases)
        display.onResult(result.exitCode, result.timedOut ? "（\(Int(skill.commandTimeout)) 秒の上限で止めました。スキルの timeout で変えられます）\n\(compact)" : compact)
        memory.setLines(from: result.output)   // 直前のコマンドの出力の行を、`vc pick` が選べる
        return "exit \(result.exitCode)\(result.timedOut ? " (timed out after \(Int(skill.commandTimeout)) s)" : "")\n\(compact)"
    }

    /// モデルへの指示（どのモデルでも共通）。
    var instructions: String {
        let finish = skill.result.repliesWithDocument
            ? "When finished, reply with the finished Markdown note ONLY: its whole text, nothing before or after it (it is saved as a file and opened for the user). If you cannot, reply: failed: <reason in Japanese>."
            : "When finished, reply with: done: <one short sentence in Japanese>. If you cannot, reply: failed: <reason in Japanese>."
        return """
        You carry out the user's request by running shell commands ONLY through the tool `run_command`. Never answer with commands in text.
        Allowed commands (the command line must start with one of these): \(skill.allowedCommands.joined(separator: " | ")).
        Commands run WITHOUT a shell: no pipes, redirects, `&&`, `;` or `$(...)`. Quote arguments that contain spaces. Run one command at a time and read its output before the next.
        Do exactly what the SKILL says; do nothing else. Never invent text to type: use only text the user actually said.
        If a command fails, read the error, fix the command, and try again (at most twice) before giving up.
        \(finish)

        SKILL (\(skill.name)):
        \(SkillPlaceholder.expand(skill.body, request: currentRequest, screenshotPath: screenshotPath()))
        """
    }

    /// `result: markdown-note` のスキル：返事を、Markdown のファイルにして開き、`done: …` に置き換える（dry-run・失敗の返事は、そのまま）。
    /// `markdown-window` は、ここでは何もしない（返事は、Markdown の本文のまま。ウィンドウに出すのは、`SkillRunner` の `RunEvent.document`）。
    /// 保存先と名前は、ここ（`ResultNote`）が決める：言語モデルは、本文だけを渡す（任意の場所へは書けない）。
    func openAsNoteIfRequested(_ reply: String) -> String {
        guard skill.result == .markdownNote, !dryRun, !reply.lowercased().hasPrefix("failed") else { return reply }
        let url: URL
        do { url = try ResultNote.write(reply) } catch { return "failed: メモを保存できません（\(error.localizedDescription)）" }
        let opened = CommandRunner.run(argv: ["open", url.path], timeout: 10, cancel: cancel)
        guard opened.exitCode == 0 else { return "failed: メモを開けません（\(url.path)）" }
        return "done: メモを開きました（\(url.path)）"
    }
}

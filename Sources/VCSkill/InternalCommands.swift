import Foundation
import VCCore
import VCDecision

/// 直前の候補（`vc find` の結果・直前のコマンドの出力の行）：`vc pick` が、選ぶ相手。1 回の実行の中だけ（記憶は、プロセスの外へ出さない・ファイルに残さない）。
/// `@unchecked Sendable` の理由：可変な状態（`entries`）は、すべて `lock` で守る。
final class OptionMemory: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        /// 選択（Tiny-Jev）に渡す、短い 1 行。
        let line: String
        /// 選んだときに、添える情報（ファイルのフルパスなど）。
        let detail: String?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func set(_ new: [Entry]) { lock.lock(); entries = new; lock.unlock() }
    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }

    /// コマンドの出力の、空でない行（`maxLines` まで）を、候補にする。
    func setLines(from output: String, maxLines: Int = 200) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        set(lines.prefix(maxLines).map { Entry(line: $0, detail: nil) })
    }
}

/// スキルの実行の中で、`vc` 自身が処理するコマンド：`vc find`（ファイルの検索）・`vc pick`（Tiny-Jev での選択）・`vc see`（スクリーンショットを見て答える）・`vc image`（スクリーンショットの加工）。モデルが呼ぶ（スキルの `allowed-commands` に書く。許可の照合は、ほかのコマンドと同じ）。
/// **外のプロセスは起こさない**（`vc` の実行ファイルを、呼び直さない：Tiny-Jev を、読み直さずに済み、検索の引数は、決まった形で受ける）。
struct InternalCommands {
    /// 依頼の文（`vc pick` が、何を選ぶかの、既定）。
    let request: String
    /// Tiny-Jev（使うときまで、読み込まない）。
    let scorer: (@Sendable () -> OptionScorer?)?
    let memory: OptionMemory
    var spotlight: FileSearch.Spotlight = FileSearch.live
    /// 画像を見るモデル（`vc see`）。実行しているスキルと、同じエンジン（この Mac の中のモデルだけ）。
    var engine: Engine = .apple
    var cancel: CancelToken?
    /// 画像を見る関数（テストで、偽物に替える）。
    var vision: @Sendable (_ image: URL, _ question: String, _ engine: Engine, _ cancel: CancelToken?) -> Result<String, ToolFailure> = { VisionModel.ask(image: $0, question: $1, engine: $2, cancel: $3) }
    var images = ImageEditing()

    static func handles(_ argv: [String]) -> Bool { argv.count >= 2 && argv[0] == "vc" && ["find", "pick", "see", "image"].contains(argv[1]) }

    /// 実行する。成功は出力の文、失敗は `ToolFailure`。
    func execute(_ argv: [String]) -> Result<String, ToolFailure> {
        let arguments = Array(argv.dropFirst(2))
        switch argv[1] {
        case "see": return see(arguments)
        case "image": return images.run(arguments)
        default: break
        }
        return Result { try argv[1] == "find" ? find(arguments) : pick(arguments) }.mapError { $0 as? ToolFailure ?? ToolFailure(exitCode: 1, message: "\($0)") }
    }

    /// 終了コードと、モデルへ返す文（失敗は、`error: …` で始める）。
    func run(_ argv: [String]) -> (exitCode: Int32, output: String) {
        switch execute(argv) {
        case let .success(text): return (0, text)
        case let .failure(failure): return (failure.exitCode, "error: \(failure.message)")
        }
    }

    // MARK: vc find

    /// 画面・言語モデルへ返す候補の数（多いと、入力に入らない）。残りは、`vc pick` が、選ぶ。
    static let shownCandidates = 15

    private func find(_ arguments: [String]) throws -> String {
        let query: FileQuery
        do { query = try FileSearch.parse(arguments) } catch { throw ToolFailure(exitCode: 2, message: "\(error)") }
        let found = FileSearch.search(query, spotlight: spotlight)
        memory.set(found.map { .init(line: $0.line(), detail: $0.path) })
        var text = FileSearch.render(Array(found.prefix(Self.shownCandidates)))
        if found.count > Self.shownCandidates { text += "\n(+\(found.count - Self.shownCandidates) more. Run: vc pick   to choose among all \(found.count))" }
        else if found.count > 1 { text += "\nTo choose the one that fits the user's request, run: vc pick" }
        return text
    }

    // MARK: vc see

    /// `vc see`：いまのスクリーンショットを見て、利用者の依頼（文字を書き出す・説明する・質問に答える）に、Markdown で答える。**引数なしが基本**（依頼の文を、そのまま使う：小さなモデルが、言い換えて、ずらさない）。`vc see "<指示>"` で、指示を、別に渡すこともできる。
    private func see(_ arguments: [String]) -> Result<String, ToolFailure> {
        let question = arguments.isEmpty ? request : arguments[0]
        guard arguments.count <= 1, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(ToolFailure(exitCode: 2, message: "usage: vc see   (no arguments: it uses the user's request), or vc see \"<instruction>\" (one quoted argument)"))
        }
        guard question.count <= Self.maxQuestion else { return .failure(ToolFailure(exitCode: 2, message: "the instruction is too long (\(Self.maxQuestion) characters at most)")) }
        switch ScreenshotStore.current() {
        case let .success(url): return vision(url, question, engine, cancel)
        case let .failure(missing): return .failure(ToolFailure(exitCode: 1, message: "\(missing)"))
        }
    }

    static let maxQuestion = 1000

    // MARK: vc pick

    private func pick(_ arguments: [String]) throws -> String {
        var query = request
        var options: [String] = []
        var threshold = Picker.defaultThreshold
        var top = 5
        var i = 0
        func value(_ flag: String) -> String? { i += 1; return i < arguments.count ? arguments[i] : nil }
        while i < arguments.count {
            let flag = arguments[i]
            switch flag {
            case "--query": guard let v = value(flag) else { throw ToolFailure(exitCode: 2, message: "--query needs a text") }; query = v
            case "--option": guard let v = value(flag) else { throw ToolFailure(exitCode: 2, message: "--option needs a text") }; options.append(v)
            case "--threshold": guard let v = value(flag), let t = Double(v), (0...1).contains(t) else { throw ToolFailure(exitCode: 2, message: "--threshold needs a number 0-1") }; threshold = t
            case "--top": guard let v = value(flag), let n = Int(v), (1...20).contains(n) else { throw ToolFailure(exitCode: 2, message: "--top needs a number 1-20") }; top = n
            case "--from-last": break   // 既定（--option がなければ、直前の候補）
            default: throw ToolFailure(exitCode: 2, message: "unknown option \(flag) (--query, --option, --threshold, --top, --from-last)")
            }
            i += 1
        }
        // 候補：--option、なければ、直前の候補（`vc find` の結果・直前のコマンドの出力）
        let entries = options.isEmpty ? memory.all : options.map { OptionMemory.Entry(line: $0, detail: nil) }
        guard !entries.isEmpty else { throw ToolFailure(exitCode: 1, message: "no options. Give --option <text> (repeatable), or run a command that prints candidates first (for example: vc find).") }
        guard !query.isEmpty else { throw ToolFailure(exitCode: 2, message: "no query (--query <text>)") }
        guard let scorer = scorer?() else { throw ToolFailure(exitCode: 1, message: "Tiny-Jev is not available (vc model download)") }
        let result: Picker.Result
        do { result = try Picker.pick(query: query, options: entries.map(\.line), threshold: threshold, scorer: scorer) } catch { throw ToolFailure(exitCode: 1, message: "\(error)") }
        var text = Picker.format(result, options: entries.map(\.line), top: top)
        // 添える情報（フルパス）：選んだもの・上位の候補に付ける
        let details = result.ranked.prefix(top).compactMap { $0.index }.compactMap { i in entries[i].detail.map { "\(i + 1)) \($0)" } }
        if !details.isEmpty { text += "\npaths:\n" + details.joined(separator: "\n") }
        return text
    }
}

/// `vc find`・`vc pick` の失敗（終了コードと、利用者・モデルへ見せる理由）。
struct ToolFailure: Error { let exitCode: Int32; let message: String }

/// `vc find`・`vc pick` を、スキルの外（端末）から使う入口（同じ処理）。成功は出力の文、失敗は理由の文。
public enum ToolCommands {
    public struct Failure: Error, Sendable { public let message: String }

    public static func find(_ arguments: [String]) -> Result<String, Failure> {
        run(["vc", "find"] + arguments, request: "", scorer: nil, memory: OptionMemory())
    }

    /// `stdinText`：標準入力の文字（`--option` がなければ、この行を、候補にする）。
    public static func pick(_ arguments: [String], stdinText: String?, scorer: @escaping @Sendable () -> OptionScorer?) -> Result<String, Failure> {
        let memory = OptionMemory()
        if let stdinText { memory.setLines(from: stdinText) }
        return run(["vc", "pick"] + arguments, request: "", scorer: scorer, memory: memory)
    }

    private static func run(_ argv: [String], request: String, scorer: (@Sendable () -> OptionScorer?)?, memory: OptionMemory) -> Result<String, Failure> {
        InternalCommands(request: request, scorer: scorer, memory: memory).execute(argv).mapError { Failure(message: $0.message) }
    }
}
